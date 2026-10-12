// perm_gen.v — the permanent generation's barrier coverage, exercised
// (cx-home/v#15 lever 2). T workers each own an Old record built before the
// first collection (so it is promoted: pre-marked at every cycle, never
// traced); every step a fresh record's ONLY reference is stored into that
// permanent object by one of the paths a pointer can take into it, and the
// collector must find it through the span's dirty bit and the stop's re-scan:
//   (a) a pointer field            old.hold = r
//   (b) a field of a nested value  old.inner.f = r   (the owner's span)
//   (c) an old array buffer        old.arr[k] = r
//   (d) a fixed array inside       old.farr[k] = r
//   (e) a push that regrows        old.list << r     (the header's data store)
//   (f) an old map                 old.m[k] = r      (the key/value buffers)
//   (g) a store through a pointer  *p = r, p = &old.hold
//   (h) a cycle in the middle of a statement: old.hold = mk_collect(r), the
//       right-hand side forcing a collection between the barrier call before
//       the statement and the store (the call after the store re-dirties).
// Each record carries its id and a checksum, pointer-free arrays remember
// which id sits where, and every window steps every slot is read back: a
// reclaimed-while-live record reads torn, or as the record that reused its
// slot. A collection is forced every 1000 steps besides the pacer's own.
// Prints `workers=.. steps=.. bad=..` and exits 1 on bad > 0. Built with
// -d vgc_cm_nobarrier (the re-scan skipped) the hazard is real: that build
// fails; the default build must not.
module main

import os

@[heap]
struct Rec {
mut:
	a   u64
	b   u64
	p   &Rec = unsafe { nil }
	sum u64
}

fn mk(i u64) &Rec {
	return &Rec{
		a:   i
		b:   i ^ 0x9e3779b97f4a7c15
		sum: i + (i ^ 0x9e3779b97f4a7c15)
	}
}

fn mk_collect(i u64) &Rec {
	r := mk(i)
	gc_collect()
	return r
}

@[inline]
fn whole(r &Rec, id u64) bool {
	return r != unsafe { nil } && r.a == id && r.sum == r.a + r.b
}

struct Inner {
mut:
	g u64
	f &Rec = unsafe { nil }
}

const window = 2048

@[heap]
struct Old {
mut:
	hold  &Rec = unsafe { nil }
	inner Inner
	arr   []&Rec
	farr  [8]&Rec
	list  []&Rec
	m     map[int]&Rec
	// the ids, pointer-free
	hid  u64
	iid  u64
	ids  []u64
	fids [8]u64
	lids []u64
	mids map[int]u64
}

fn new_old() &Old {
	return &Old{
		arr: []&Rec{len: window, init: unsafe { nil }}
		ids: []u64{len: window}
	}
}

fn worker(id u64, steps int, mut old Old) u64 {
	mut bad := u64(0)
	mut junk := []u8{}
	for s in 0 .. steps {
		i := u64(s) + id * 100000000
		k := s % window
		mut r := mk(i)
		match s % 8 {
			0 {
				old.hold = r
				old.hid = i
			}
			1 {
				old.inner.f = r
				old.iid = i
			}
			2 {
				old.arr[k] = r
				old.ids[k] = i
			}
			3 {
				old.farr[s & 7] = r
				old.fids[s & 7] = i
			}
			4 {
				old.list << r
				old.lids << i
			}
			5 {
				old.m[s & 511] = r
				old.mids[s & 511] = i
			}
			6 {
				mut p := &old.hold
				unsafe {
					*p = r
				}
				old.hid = i
			}
			else {
				r = unsafe { nil }
				old.hold = mk_collect(i)
				old.hid = i
			}
		}
		r = unsafe { nil }
		// allocation pressure for the pacer's own cycles, and one forced
		junk = []u8{len: 4096}
		if s % 1000 == 999 {
			gc_collect()
		}
		if k == window - 1 {
			if !whole(old.hold, old.hid) {
				bad++
			}
			if !whole(old.inner.f, old.iid) {
				bad++
			}
			for q in 0 .. window {
				if old.arr[q] != unsafe { nil } && !whole(old.arr[q], old.ids[q]) {
					bad++
				}
			}
			for q in 0 .. 8 {
				if old.farr[q] != unsafe { nil } && !whole(old.farr[q], old.fids[q]) {
					bad++
				}
			}
			for q in 0 .. old.list.len {
				if !whole(old.list[q], old.lids[q]) {
					bad++
				}
			}
			for mk_, rr in old.m {
				if !whole(rr, old.mids[mk_]) {
					bad++
				}
			}
		}
	}
	return bad + u64(junk.len & 0)
}

fn main() {
	t := os.getenv('T').int()
	workers := if t > 0 { t } else { 4 }
	steps := if os.getenv('STEPS').int() > 0 { os.getenv('STEPS').int() } else { 40000 }
	// the permanent generation: the Old records, built before the first cycle
	mut olds := []&Old{}
	for _ in 0 .. workers {
		olds << new_old()
	}
	gc_collect() // the promotion cycle (VGC_PERM_CYCLE=1)
	gc_collect()
	mut ts := []thread u64{}
	for w in 0 .. workers {
		ts << spawn worker(u64(w + 1), steps, mut olds[w])
	}
	mut bad := u64(0)
	for th in ts {
		bad += th.wait()
	}
	println('workers=${workers} steps=${steps} bad=${bad}')
	if bad > 0 {
		exit(1)
	}
}
