// budget.v — the minor cycles' budget (cx-home/v#56 step 2, `-gc e`; the
// doc at vgc_young_minors in vlib/builtin/vgc_d_vgc.c.v). A ring of SLOTS
// batches of 4,096 records (256 KB each) is kept live; every step replaces one
// batch with a new one (the old batch dies) and drops 256 small records, so
// the batches born since the last stop are live at the next one, promoted by
// a minor cycle (their marks stick) and dead soon after — the shape of a
// parse-and-emit loop over a large document. Without the budget a run of
// minors carries the sticky marked set and the goal up until the cap of eight
// minors; with it the full cycle's goal bounds the minors. Prints heap_mb=
// (the heap at the end), peak_mb= (the largest heap size read after any
// step), alloc_mb=, minors= and goal_mb= (the last full cycle's goal).
module main

import os

@[heap]
struct Rec {
mut:
	v   u64
	pad [7]u64
}

@[heap]
struct Ring {
mut:
	hold [][]&Rec
}

fn batch(v u64) []&Rec {
	mut b := []&Rec{len: 4096, init: unsafe { nil }}
	for i in 0 .. 4096 {
		b[i] = &Rec{
			v: v + u64(i)
		}
	}
	return b
}

fn main() {
	steps := os.getenv_opt('STEPS') or { '400' }.int()
	slots := 16
	mut ring := &Ring{
		hold: [][]&Rec{len: slots}
	}
	for k in 0 .. slots {
		ring.hold[k] = batch(u64(k))
	}
	gc_collect()
	mut g := &Rec(unsafe { nil })
	mut peak := usize(0)
	mut expect := u64(0)
	for s in 0 .. steps {
		for j in 0 .. 256 {
			g = &Rec{
				v: u64(j)
			}
		}
		k := s % slots
		ring.hold[k] = batch(u64(s) * 4096)
		expect = u64(s) * 4096
		u := gc_heap_usage()
		if u.heap_size > peak {
			peak = u.heap_size
		}
	}
	mut bad := 0
	for k in 0 .. slots {
		b := ring.hold[k]
		if b.len != 4096 || b[0].v + 4095 != b[4095].v {
			bad++
		}
	}
	last := ring.hold[(steps - 1) % slots][0].v
	if last != expect {
		bad++
	}
	u := gc_heap_usage()
	println('done steps=${steps} bad=${bad} last=${g.v} heap_mb=${u.heap_size / (1024 * 1024)} peak_mb=${peak / (1024 * 1024)} alloc_mb=${gc_total_allocated() / (1024 * 1024)} minors=${vgc_minor_cycles_count()} goal_mb=${vgc_full_goal_probe() / (1024 * 1024)}')
}
