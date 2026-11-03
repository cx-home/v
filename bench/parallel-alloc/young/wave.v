// wave.v — a minor cycle's trigger is its share of the full cycle's headroom
// (cx-home/v#56 lever 8, `-gc e`; the doc at vgc_minor_budget in
// vlib/builtin/vgc_gc_d_vgc.c.v). A live set of SLOTS batches of 4,096
// records (256 KB each) is built and a full cycle run (gc_collect), then a
// wave of WAVE_MB of young garbage — small records nothing holds — is
// allocated with the live set untouched: the shape of binary-trees after its
// stretch tree, where the regime's minors run only at twice the sticky
// marked set and the young garbage fills the heap to that goal between two
// stops (measure/collector-epic-80: 13 arenas and 270 MB of pool at 49 MB
// live). Prints heap_mb= (the heap at the end), peak_mb= (the largest heap
// size read during the wave), alloc_mb=, minors= and goal_mb= (the last
// full cycle's goal).
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
	wave_mb := os.getenv_opt('WAVE_MB') or { '96' }.int()
	slots := 192 // 48 MB live
	mut ring := &Ring{
		hold: [][]&Rec{len: slots}
	}
	for k in 0 .. slots {
		ring.hold[k] = batch(u64(k))
	}
	gc_collect()
	minors0 := vgc_minor_cycles_count()
	mut g := &Rec(unsafe { nil })
	mut peak := usize(0)
	recs := wave_mb * 1024 * 1024 / 64 // 64-byte records
	for i := 0; i < recs; i++ {
		g = &Rec{
			v: u64(i)
		}
		if i & 0xffff == 0 {
			u := gc_heap_usage()
			if u.heap_size > peak {
				peak = u.heap_size
			}
		}
	}
	mut bad := 0
	for k in 0 .. slots {
		b := ring.hold[k]
		if b.len != 4096 || b[0].v != u64(k) || b[4095].v != u64(k) + 4095 {
			bad++
		}
	}
	u := gc_heap_usage()
	println('done bad=${bad} last=${g.v} heap_mb=${u.heap_size / (1024 * 1024)} peak_mb=${peak / (1024 * 1024)} alloc_mb=${gc_total_allocated() / (1024 * 1024)} minors=${vgc_minor_cycles_count() - minors0} goal_mb=${vgc_full_goal_probe() / (1024 * 1024)}')
}
