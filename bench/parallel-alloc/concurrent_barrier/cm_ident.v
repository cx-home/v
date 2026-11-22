// cm_ident.v — a store whose target is a plain identifier that C reaches through a
// pointer, during the concurrent mark (https://github.com/cx-home/v/issues/83, the
// family of https://github.com/cx-home/v/issues/82 and
// https://github.com/cx-home/cx-core-code/issues/279). Two such identifiers:
//   MODE=mut  — a `mut` parameter of a struct type: `s = v` is C `*s = v`, and the
//               caller passed the address of an element of an old (already
//               scanned) heap array; 16 lanes a step, each into its own slot of a
//               4,096-slot window, so a lost record is still named when checked;
//   MODE=heap — an auto-heap local (its address escapes, so cgen keeps it in a heap
//               box): `box.r = v` is C `box->r = v`, and the box is old by then.
//               One record every 512 steps (the box keeps one), so this mode
//               rarely meets the hazard; it is a control that must stay whole.
// T workers each move a record whose only reference sits deep in a ballast chain
// (unscanned until the markers reach it) through that store, and drop the chain's
// reference, while a collector thread forces a collection every 2 ms. With the
// store's barrier the old object is re-scanned at termination; without it the
// record is white when the markers reach the chain's tail, and swept while the
// old object still names it. Each record carries its id and a checksum, so a
// reclaimed record reads back torn or as the record that reused its slot.
// Prints `mode=.. bad=..` and exits 1 on bad > 0.
module main

import time
import os

@[heap]
struct Rec {
mut:
	a   u64
	b   u64
	p   &Rec = unsafe { nil }
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

const lanes = 16

const window = 4096

// Slot is a value struct with a pointer, stored whole
struct Slot {
mut:
	r  &Rec = unsafe { nil }
	id u64
	// a size class of its own: no newborn shares the box's span (a newborn's span is
	// re-scanned at termination whatever the barrier did)
	pad [30]u64
}

struct Old {
mut:
	slots   []Slot
	ballast &Rec = unsafe { nil }
	hidden  []u64
}

// put stores `v` through the mut parameter: C `*s = v`
@[noinline]
fn put(mut s Slot, v Slot) {
	s = v
}

fn worker(id u64, steps int, heap_mode bool) u64 {
	mut bad := u64(0)
	mut old := &Old{
		slots: []Slot{len: window}
	}
	for k in 0 .. 20000 {
		old.ballast = mk(u64(k), old.ballast)
		if k < lanes {
			if k == 0 {
				old.hidden = []u64{len: lanes}
			}
			old.hidden[k] = u64(voidptr(old.ballast))
		}
	}
	// lane 0's auto-heap local (MODE=heap)
	mut box := Slot{}
	seen := &box
	// the address escapes into a heap array, so cgen boxes `box` on the heap
	mut keep := []&Slot{len: 1}
	keep[0] = seen
	for s in 0 .. steps {
		i := u64(s) + id * 100000000
		for h in 0 .. lanes {
			if heap_mode && h == 0 && s % 512 != 0 {
				// lane 0's record ages 512 steps before it moves: it is white when a
				// cycle that started since it was made reaches the move
				continue
			}
			mut tail := unsafe { &Rec(voidptr(old.hidden[h])) }
			mut treasure := tail.q
			tail.q = unsafe { nil }
			if treasure != unsafe { nil } {
				if heap_mode && h == 0 {
					box.r = treasure
					box.id = treasure.a
				} else if !heap_mode {
					put(mut old.slots[(s * lanes + h) % window], Slot{ r: treasure, id: treasure.a })
				}
			}
			tail.q = mk(i * lanes + u64(h) + 50000000, unsafe { nil })
		}
		if s % 64 == 63 {
			if heap_mode {
				if keep[0].r != unsafe { nil } && !whole(keep[0].r, keep[0].id) {
					bad++
				}
			} else {
				for q in 0 .. window {
					if old.slots[q].r != unsafe { nil } && !whole(old.slots[q].r, old.slots[q].id) {
						bad++
					}
				}
			}
		}
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
	t := if os.getenv('T').int() > 0 { os.getenv('T').int() } else { 4 }
	steps := if os.getenv('STEPS').int() > 0 { os.getenv('STEPS').int() } else { 40000 }
	mode := os.getenv('MODE')
	heap_mode := mode == 'heap'
	mut ts := []thread u64{}
	for p in 0 .. t {
		ts << spawn worker(u64(p + 1), steps, heap_mode)
	}
	ts << spawn collector(400)
	mut bad := u64(0)
	for th in ts {
		bad += th.wait()
	}
	println('mode=${mode} t=${t} steps=${steps} bad=${bad}')
	if bad > 0 {
		exit(1)
	}
}
