// minor.v — the minor cycle exercised (cx-home/v#56 step 2, `-gc e`; the
// cycle's doc at vgc_young_minors in vlib/builtin/vgc_d_vgc.c.v). An old
// graph is built — a chain of 65,536 records and a holder of SLOTS slots —
// and a full cycle forced (gc_collect), so it is old and the regime armed.
// Then STEPS rounds, each allocating 256 records it drops (the young garbage
// the pacer's cycles reclaim) and one young record it stores into a slot of the
// old holder (old.hold[k] = r: the record's only reference, found at a minor
// cycle through the holder buffer's card), replacing what the slot held; the
// sum of the values the slots hold is kept beside. At the end every slot is
// read back and summed (bad=0 when the sum is the kept one), the chain walked
// (chain=65536), and the counts printed: the heap's size and the bytes
// allocated in all (heap_mb=, alloc_mb=: the cycles reclaimed the garbage),
// minors= (vgc_minor_cycles_count) and missed= (-d vgc_cm_verify's count, 0
// under other builds).
module main

import os

@[heap]
struct Rec {
mut:
	v    u64
	pad  [5]u64
	next &Rec = unsafe { nil }
}

@[heap]
struct Old {
mut:
	hold  []&Rec
	chain &Rec = unsafe { nil }
}

fn mk(v u64) &Rec {
	return &Rec{
		v: v
	}
}

fn main() {
	steps := os.getenv_opt('STEPS') or { '4000' }.int()
	slots := 4096
	mut old := &Old{
		hold: []&Rec{len: slots, init: unsafe { nil }}
	}
	mut head := &Rec(unsafe { nil })
	for i in 0 .. 65536 {
		mut r := mk(u64(i))
		r.next = head
		head = r
	}
	old.chain = head
	gc_collect()
	mut expect := u64(0)
	mut g := &Rec(unsafe { nil })
	for s in 0 .. steps {
		for j in 0 .. 256 {
			g = mk(u64(j))
		}
		k := s % slots
		y := mk(u64(s) * 7 + 1)
		if old.hold[k] != unsafe { nil } {
			expect -= old.hold[k].v
		}
		old.hold[k] = y
		expect += y.v
	}
	mut sum := u64(0)
	for k in 0 .. slots {
		if old.hold[k] != unsafe { nil } {
			sum += old.hold[k].v
		}
	}
	mut n := 0
	mut p := old.chain
	for p != unsafe { nil } {
		n++
		p = p.next
	}
	bad := if sum == expect { 0 } else { 1 }
	u := gc_heap_usage()
	println('done steps=${steps} bad=${bad} chain=${n} last=${g.v} heap_mb=${u.heap_size / (1024 * 1024)} alloc_mb=${gc_total_allocated() / (1024 * 1024)} minors=${vgc_minor_cycles_count()} missed=${vgc_cm_verify_missed_count()}')
}
