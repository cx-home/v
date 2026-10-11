// cm_barrier.v — the concurrent mark's barrier coverage, exercised (cx-private#1910).
// T worker pairs move pointer-bearing records while a collector thread forces a
// collection every 2 ms; each worker also holds a 20,000-record ballast list so
// the concurrent middle is long enough for most stores to land inside it. Every
// path a pointer can take into an already-scanned (black) object during the
// middle is on the loop:
//   (a) a fresh record filled from a pointer read out of an old one (decl_assign
//       fills a newborn: alloc-GRAY, no barrier);
//   (b) the only reference moved into an OLD object's field (the codegen barrier);
//   (c) the only reference sent through a channel to the partner thread (the
//       channels.c.v barrier), which stores it into ITS old array;
//   (d) the only reference copied into an old array buffer (array set barrier)
//       and into an old map (map_set barrier).
// Each record carries its id and a checksum, and the window remembers which id
// sits in each slot: a reclaimed-while-live record reads back torn, or as the
// record that reused its slot. Prints `steps=.. bad=..` and exits 1 on bad > 0.
// Built with -d vgc_cm_nobarrier the termination re-scan is skipped and the
// hazard is real: that build fails; the default build must not.
module main

import time
import os

@[heap]
struct Rec {
mut:
	a   u64
	b   u64
	p   &Rec = unsafe { nil }
	// the treasure slot of a ballast node (see worker): a record whose only
	// reference sits deep in the chain the markers reach last
	q   &Rec = unsafe { nil }
	sum u64
}

fn mk(i u64, p &Rec) &Rec {
	return &Rec{
		a:   i
		b:   i ^ 0x9e3779b97f4a7c15
		p:   p
		sum: i + (i ^ 0x9e3779b97f4a7c15)
	}
}

@[inline]
fn whole(r &Rec, id u64) bool {
	return r != unsafe { nil } && r.a == id && r.sum == r.a + r.b
}

const window = 4096

struct Old {
mut:
	hold &Rec = unsafe { nil }
	arr  []&Rec
	ids  []u64
	m    map[int]&Rec
	mids map[int]u64
	// the ballast: a chain the markers must walk every cycle, and its tail,
	// held as an integer in a pointer-free buffer so the collector reaches the
	// tail only through the chain (the stack and this struct would mark it
	// first)
	ballast &Rec = unsafe { nil }
	hidden  []u64
	tids    []u64
}

fn worker(id u64, steps int, tx chan &Rec, rx chan &Rec) u64 {
	mut bad := u64(0)
	// the old objects: allocated once, black after the first cycle's root scan
	mut old := &Old{
		arr: []&Rec{len: window}
		ids: []u64{len: window}
	}
	mut mine := &Old{
		arr: []&Rec{len: window}
		ids: []u64{len: window}
	}
	for k in 0 .. 20000 {
		old.ballast = mk(u64(k), old.ballast)
		if k < 8 {
			if k == 0 {
				old.hidden = []u64{len: 8}
			}
			old.hidden[k] = u64(voidptr(old.ballast))
		}
	}
	old.tids = []u64{len: window}
	mut carry := mk(id, unsafe { nil })
	for s in 0 .. steps {
		i := u64(s) + id * 100000000
		// (e) the hazard proper: the treasure's only reference moves from the
		// chain's tail (unscanned until the markers reach it) into the old
		// array (scanned long before) and leaves the tail — with the store's
		// barrier the array is re-scanned at termination; without it the
		// treasure is white when the markers reach the tail, and swept.
		for h in 0 .. 8 {
			mut tail := unsafe { &Rec(voidptr(old.hidden[h])) }
			treasure := tail.q
			tail.q = unsafe { nil }
			if treasure != unsafe { nil } {
				slot := (s * 8 + h + window / 2) % window
				old.arr[slot] = treasure
				old.ids[slot] = treasure.a
			}
			tail.q = mk(i * 8 + u64(h) + 50000000, unsafe { nil })
		}
		// (a) fresh from old: the only reference to `carry` now lives in `fresh`
		fresh := mk(i, carry)
		carry = unsafe { nil }
		// (b) into an old object's field, (d) into an old array slot and an old map
		old.hold = fresh
		old.arr[s % window] = old.hold
		old.ids[s % window] = i
		old.m[s & 255] = old.arr[s % window]
		old.mids[s & 255] = i
		old.hold = unsafe { nil }
		// (c) through the channel: the record stored seven steps ago goes to the
		// partner, which keeps what it receives in its own old array
		k := (s + window - 7) % window
		sent := if old.arr[k] == unsafe { nil } { old.arr[s % window] } else { old.arr[k] }
		tx <- sent
		got := <-rx
		if got == unsafe { nil } {
			bad++
			continue
		}
		mine.arr[s % window] = got
		mine.ids[s % window] = got.a
		if !whole(got, got.a) || (got.p != unsafe { nil } && got.p.sum != got.p.a + got.p.b) {
			bad++
		}
		if s % window == window - 1 {
			for q in 0 .. window {
				if !whole(old.arr[q], old.ids[q]) {
					bad++
				}
				if !whole(mine.arr[q], mine.ids[q]) {
					bad++
				}
			}
			for mk_, r in old.m {
				if !whole(r, old.mids[mk_]) {
					bad++
				}
			}
		}
		// the chain continues from the partner's record
		carry = got
	}
	return bad
}

fn collector(n int) u64 {
	for _ in 0 .. n {
		gc_collect()
		time.sleep(2 * time.millisecond)
	}
	return 0
}

fn main() {
	t := os.getenv('T').int()
	pairs := if t > 0 { t } else { 4 }
	steps := if os.getenv('STEPS').int() > 0 { os.getenv('STEPS').int() } else { 40000 }
	mut ts := []thread u64{}
	for p in 0 .. pairs {
		a := chan &Rec{cap: 1}
		b := chan &Rec{cap: 1}
		ts << spawn worker(u64(p * 2 + 1), steps, a, b)
		ts << spawn worker(u64(p * 2 + 2), steps, b, a)
	}
	ts << spawn collector(400)
	mut bad := u64(0)
	for th in ts {
		bad += th.wait()
	}
	println('pairs=${pairs} steps=${steps} bad=${bad}')
	if bad > 0 {
		exit(1)
	}
}
