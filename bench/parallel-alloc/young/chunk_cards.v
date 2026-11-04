// chunk_cards.v — the card barrier resolves a store's card without an arena
// lookup, in every arena (cx-home/v#56 lever 10, `-gc e`; the doc at
// vgc_chunk_cards in thirdparty/vgc/vgc_platform.h). A live set of LIVE_MB of
// 64-byte records (4 batches of 4,096 per MB, held by an old ring) is built
// across several arenas and a full cycle run under VGC_YOUNG=1, so every
// record is old and the regime armed; then, for RECS old records spread over
// the batches (and so over the arenas), a young record is stored into the old
// one REPEAT times, and young garbage nothing holds is allocated until a
// minor cycle runs. Under -d vgc_wb_count prints calls= (the barrier calls the
// stores made: one per record's page when the generated C's gate reads every
// arena's card, one per store into any arena but the first when it reads the
// first arena's record alone), slow= (the calls that resolved the arena out
// of line), arenas=, and bad= (the stored records the minor lost: 0).
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
	live_mb := os.getenv_opt('LIVE_MB') or { '256' }.int()
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
	arenas := vgc_arenas_count()
	c0 := vgc_wb_calls_count()
	s0 := vgc_wb_slow_calls_count()
	for s in 0 .. recs {
		k := s * (slots / recs)
		store_into(mut ring.hold[k][7], &Rec{
			v: 1_000_000 + u64(s)
		}, repeat)
	}
	calls := vgc_wb_calls_count() - c0
	slow := vgc_wb_slow_calls_count() - s0
	minors0 := vgc_minor_cycles_count()
	mut g := &Rec(unsafe { nil })
	mut i := u64(0)
	for vgc_minor_cycles_count() == minors0 && i < 16_000_000 {
		g = &Rec{
			v: i
		}
		i++
	}
	gc_collect()
	mut bad := 0
	for s in 0 .. recs {
		k := s * (slots / recs)
		r := ring.hold[k][7].next
		if r == unsafe { nil } || r.v != 1_000_000 + u64(s) {
			bad++
		}
	}
	println('done bad=${bad} calls=${calls} slow=${slow} arenas=${arenas} recs=${recs} repeat=${repeat} minors=${vgc_minor_cycles_count() - minors0} last=${g.v}')
}
