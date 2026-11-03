// hold.v — the full cycle that follows a run of minor cycles collects at its
// share of the headroom, not at twice the minors' marked set (cx-home/v#56
// lever 8, the closing full; `-gc e`; the doc at vgc_minor_next in
// vlib/builtin/vgc_gc_d_vgc.c.v). A live set of SLOTS batches of 4,096
// records (256 KB each) is built and a full cycle run (gc_collect), then a
// wave of HOLD_MB of young records is allocated and every one is kept in an
// old array (an old-to-young pointer through the cards), so each minor marks
// the records allocated since the last stop and the marked set climbs by one
// share a minor; then WAVE_MB of young garbage nothing holds. Once the
// marked set reads twice the last full cycle's (or the run's count is
// reached) the next cycle is full: before, that full's trigger was the
// pacer's (twice the minors' marked set — a set a minor does not measure, it
// keeps the young spans the cards reach whole) and the garbage ran the heap
// to it (binary-trees 18: marked 361 MB after the eighth minor at 108 MB
// live, goal 723, five arenas carved; measure/collector-epic-84, the F
// trace). Prints kept_mb= (the heap after the hold wave), heap_mb= (the heap
// at the end), peak_mb= (the largest heap size read during both waves),
// alloc_mb=, minors= and goal_mb= (the last full cycle's goal). The pacer's
// term is the whole GOGC one (VGC_ONE_THREAD_PCT=100 in the test: cx runs
// several allocating threads, the trace reads threads=6).
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
	keep []&Rec
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
	hold_mb := os.getenv_opt('HOLD_MB') or { '64' }.int()
	slots := 192 // 48 MB live
	recs := hold_mb * 1024 * 1024 / 64 // 64-byte records
	mut ring := &Ring{
		hold: [][]&Rec{len: slots}
		keep: []&Rec{cap: recs}
	}
	for k in 0 .. slots {
		ring.hold[k] = batch(u64(k))
	}
	gc_collect()
	minors0 := vgc_minor_cycles_count()
	mut peak := usize(0)
	for i := 0; i < recs; i++ {
		ring.keep << &Rec{
			v: u64(i)
		}
		if i & 0xffff == 0 {
			u := gc_heap_usage()
			if u.heap_size > peak {
				peak = u.heap_size
			}
		}
	}
	kept_mb := gc_heap_usage().heap_size / (1024 * 1024)
	// then the wave: WAVE_MB of young garbage nothing holds — the full that
	// closes the run of minors must run one share on, not at twice the
	// minors' marked set
	wave_mb := os.getenv_opt('WAVE_MB') or { '96' }.int()
	wrecs := wave_mb * 1024 * 1024 / 64
	mut g := &Rec(unsafe { nil })
	for i := 0; i < wrecs; i++ {
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
	u := gc_heap_usage()
	if u.heap_size > peak {
		peak = u.heap_size
	}
	mut bad := 0
	if g.v != u64(wrecs - 1) {
		bad++
	}
	for k in 0 .. slots {
		b := ring.hold[k]
		if b.len != 4096 || b[0].v != u64(k) || b[4095].v != u64(k) + 4095 {
			bad++
		}
	}
	for i := 0; i < recs; i += 4093 {
		if ring.keep[i].v != u64(i) {
			bad++
		}
	}
	println('done bad=${bad} kept=${ring.keep.len} kept_mb=${kept_mb} heap_mb=${u.heap_size / (1024 * 1024)} peak_mb=${peak / (1024 * 1024)} alloc_mb=${gc_total_allocated() / (1024 * 1024)} minors=${vgc_minor_cycles_count() - minors0} goal_mb=${vgc_full_goal_probe() / (1024 * 1024)}')
}
