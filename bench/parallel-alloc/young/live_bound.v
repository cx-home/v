// live_bound.v — the young regime's minor cycles serve a live set under the
// bound (cx-home/v#56 lever 12, `-gc e -d vgc_wb_count`; the doc at
// vgc_young_live_max in vlib/builtin/vgc_d_vgc.c.v). A live set of LIVE_MB
// (batches of 4,096 64-byte records, 256 KB each) is built and a full cycle
// run (gc_collect: the full decides the regime for the cycles after it), then
// RECS pointer stores into old records (the last batches, a record each, none of them in
// the start-up's permanent generation; a live set of fewer batches than RECS takes
// several records a batch), each REPEAT times, are counted at
// the barrier, then a wave of WAVE_MB of young garbage nothing holds is
// allocated. Prints calls= (the barrier calls the stores made), minors= (the
// minor cycles during the wave) and bad= (the stored pointers and the live
// set read back after a last full cycle).
module main

import os

@[heap]
struct Rec {
mut:
	v    u64
	next &Rec = unsafe { nil }
	pad  [6]u64
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

@[noinline]
fn store_into(mut old Rec, y &Rec, repeat int) {
	for _ in 0 .. repeat {
		old.next = y
	}
}

fn main() {
	live_mb := os.getenv_opt('LIVE_MB') or { '48' }.int()
	wave_mb := os.getenv_opt('WAVE_MB') or { '96' }.int()
	recs := os.getenv_opt('RECS') or { '64' }.int()
	repeat := os.getenv_opt('REPEAT') or { '1000' }.int()
	slots := live_mb * 4 // 256 KB a batch
	mut ring := &Ring{
		hold: [][]&Rec{len: slots}
	}
	for k in 0 .. slots {
		ring.hold[k] = batch(u64(k))
	}
	gc_collect()
	c0 := vgc_wb_calls_count()
	for s in 0 .. recs {
		store_into(mut ring.hold[slots - 1 - s % slots][7 + s / slots], &Rec{
			v: 1_000_000 + u64(s)
		}, repeat)
	}
	calls := vgc_wb_calls_count() - c0
	minors0 := vgc_minor_cycles_count()
	mut g := &Rec(unsafe { nil })
	wrecs := wave_mb * 1024 * 1024 / 64
	for i := 0; i < wrecs; i++ {
		g = &Rec{
			v: u64(i)
		}
	}
	minors := vgc_minor_cycles_count() - minors0
	gc_collect()
	mut bad := 0
	for s in 0 .. recs {
		r := ring.hold[slots - 1 - s % slots][7 + s / slots].next
		if r == unsafe { nil } || r.v != 1_000_000 + u64(s) {
			bad++
		}
	}
	for k in 0 .. slots {
		b := ring.hold[k]
		if b.len != 4096 || b[0].v != u64(k) || b[4095].v != u64(k) + 4095 {
			bad++
		}
	}
	println('done bad=${bad} calls=${calls} minors=${minors} live_mb=${live_mb} recs=${recs} last=${g.v}')
}
