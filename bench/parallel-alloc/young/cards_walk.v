// cards_walk.v — a minor cycle's card scan is sized by the dirty cards, not by
// the heap's span count (cx-home/v#56 lever 9, `-gc e`; the doc at
// vgc_minor_cards in vlib/builtin/vgc_gc_d_vgc.c.v). A live set of LIVE_MB of
// 64-byte records (4 batches of 4,096 per MB, held by an old ring) is built
// and a full cycle run, so every record is old and the young regime armed;
// then STORES young records are stored into old records of STORES different
// batches (one card each), and young garbage nothing holds is allocated until
// a minor cycle runs. Prints the minor's walk as the collector counted it:
// visited= (the spans whose cards it read), card_spans= (the spans a card
// was set in), old_objs= (the old objects it scanned), nspans= (the heap's
// spans in use), and bad= (the stored records the minor lost: 0).
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

fn main() {
	live_mb := os.getenv_opt('LIVE_MB') or { '96' }.int()
	stores := os.getenv_opt('STORES') or { '10' }.int()
	slots := live_mb * 4 // 256 KB a batch
	mut ring := &Ring{
		hold: [][]&Rec{len: slots}
	}
	for k in 0 .. slots {
		ring.hold[k] = batch(u64(k))
	}
	gc_collect()
	// one young record into one old record of every (slots / stores)th batch
	for s in 0 .. stores {
		k := s * (slots / stores)
		ring.hold[k][7].next = &Rec{
			v: 1_000_000 + u64(s)
		}
	}
	minors0 := vgc_minor_cycles_count()
	mut g := &Rec(unsafe { nil })
	mut i := u64(0)
	for vgc_minor_cycles_count() == minors0 && i < 16_000_000 {
		g = &Rec{
			v: i
		}
		i++
	}
	minors := vgc_minor_cycles_count() - minors0
	visited, spans, objs := vgc_minor_last_walk()
	mut bad := 0
	for s in 0 .. stores {
		k := s * (slots / stores)
		r := ring.hold[k][7].next
		if r == unsafe { nil } || r.v != 1_000_000 + u64(s) {
			bad++
		}
	}
	println('done bad=${bad} minors=${minors} visited=${visited} card_spans=${spans} old_objs=${objs} nspans=${vgc_spans_in_use()} slots=${slots} garbage=${i} last=${g.v}')
}
