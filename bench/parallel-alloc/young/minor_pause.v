// minor_pause.v — a minor cycle's stop is not the pause the next concurrent
// cycle's stops are judged by (cx-home/v#56 lever 11; cx-private#1910's
// back-off, vgc_stw_last_pause_ns in vlib/builtin/vgc_gc_d_vgc.c.v). A live
// set of 192 batches of 4,096 records (48 MB) is built and a full cycle run
// (gc_collect: a stop-the-world mark of the live set, ~10 ms), the probe
// vgc_stw_last_pause_probe read, then young garbage nothing holds is
// allocated until one minor cycle has run (and no other full), and the probe
// read again. Prints done minors= fulls= pause0_us= pause1_us=. Before, the
// minor's stop (~1 ms) replaced the full's: a concurrent full whose two stops
// read ~1.3 ms then "lost" against it and backed off to stop-the-world fulls
// for 8, 16, 32, 64 cycles (binary-trees 18 cx interpreted: 36 of the 44
// fulls at 49 MB live stop-the-world after the concurrent test itself was
// judged by the full's mark).
module main

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
	slots := 192 // 48 MB live
	mut ring := &Ring{
		hold: [][]&Rec{len: slots}
	}
	for k in 0 .. slots {
		ring.hold[k] = batch(u64(k))
	}
	gc_collect()
	minors0 := vgc_minor_cycles_count()
	cycles0 := gc_cycles()
	pause0 := vgc_stw_last_pause_probe()
	mut g := &Rec(unsafe { nil })
	mut i := u64(0)
	// young garbage until one minor cycle has run (a share of the full
	// cycle's headroom), 512 MB at most
	for i < 8 * 1024 * 1024 {
		g = &Rec{
			v: i
		}
		i++
		if i & 0xffff == 0 && vgc_minor_cycles_count() > minors0 {
			break
		}
	}
	minors := vgc_minor_cycles_count() - minors0
	fulls := gc_cycles() - cycles0 - minors
	pause1 := vgc_stw_last_pause_probe()
	mut bad := 0
	if g.v != i - 1 {
		bad++
	}
	for k in 0 .. slots {
		b := ring.hold[k]
		if b.len != 4096 || b[0].v != u64(k) || b[4095].v != u64(k) + 4095 {
			bad++
		}
	}
	println('done bad=${bad} minors=${minors} fulls=${fulls} pause0_us=${pause0 / 1000} pause1_us=${pause1 / 1000} alloc_mb=${gc_total_allocated() / (1024 * 1024)}')
}
