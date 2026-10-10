// vgc_grow_gate_growing_test.v — on a heap whose live set keeps growing, the
// VGCG-1 grow gate adds no collections (cx-private batch I-1, Letter 190).
//
// The gate defers an arena carve to one collection when the heap has grown
// vgc_grow_gate_pct of the way from the last marked set to the goal. That
// pays when the collection finds garbage the growth can reuse. While the live
// set still grows, the collection marks a set that is mostly live, and the
// trigger recompute after it shortens the next cycle. `cx fmt` of an
// 8k-record document took 15 collections instead of 10, +15 % wall time
// (perf-ratchet tooling.fmt_8k_ms 1304 -> 1506 ms on 169397f61).
//
// Shape: a live set that grows to 256 MB in 2 KB records, each record built
// beside one 2 KB transient, the way a formatter keeps its output and drops
// its scratch. The child runs the build with the gate at its default and with
// it off (VGC_GROW_GATE_PCT=0), three times each, and counts the collections
// in VGC_GCTRACE, the two arms interleaved (off, on, off, on, ...) so both see
// the same load. The gate at its default must take no more collections than
// the most the gate-off arm took, and its total pause time (the least of its
// runs) no more than 1.25x the gate off's least plus 10 ms.
//
// Why the gate-off arm's MOST, not its least: the pacer is adaptive, and a
// loaded box can take a collection AWAY as well as add one — a stretched
// pause reads as GC overhead, the headroom doubles a cycle earlier, and the
// run ends one collection short (CI ubuntu/FreeBSD and dev2 at load 220-310:
// gate off 9,10,10,9,10,9 against default 10 every run; cx-home/v#16). The
// gate's own regression is a collection beyond the whole off range: with the
// growing guard defeated (run the test with VGC_GROW_GATE_GROWTH_PCT=100:
// the children inherit it) the shape takes 11
// against the off arm's 9-10, and red here.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_grow_gate_growing_test.v
module main

import os

const rec = 2048
const live_bytes = 256 * 1024 * 1024

fn grow() int {
	mut keep := [][]u8{cap: live_bytes / rec}
	mut sink := 0
	for i in 0 .. live_bytes / rec {
		scratch := []u8{len: rec, init: u8(i)}
		mut r := []u8{len: rec}
		r[0] = scratch[i % rec]
		sink += r[0]
		keep << r
	}
	return keep.len + sink % 2
}

struct Trace {
	cycles   int
	pause_us u64
}

fn run_child(pct string) Trace {
	env := if pct == '' { '' } else { 'VGC_GROW_GATE_PCT=${pct} ' }
	r := os.execute('VGC_GROW_CHILD=1 VGC_GCTRACE=1 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, 'the child failed (${pct}): ${r.output}'
	mut t := Trace{}
	for line in r.output.split_into_lines() {
		if !line.starts_with('[gc ') {
			continue
		}
		t = Trace{
			cycles:   t.cycles + 1
			pause_us: t.pause_us + line.all_after('pause=').all_before('us').u64()
		}
	}
	assert line_count_ok(r.output), 'the child printed no GROW-DONE line: ${r.output}'
	return t
}

// least keeps the fewer collections and the lesser pause time of two runs.
fn least(a Trace, b Trace) Trace {
	return Trace{
		cycles:   if b.cycles < a.cycles { b.cycles } else { a.cycles }
		pause_us: if b.pause_us < a.pause_us { b.pause_us } else { a.pause_us }
	}
}

fn line_count_ok(out string) bool {
	return out.split_into_lines().any(it.starts_with('GROW-DONE='))
}

fn test_a_growing_heap_takes_no_extra_collections() {
	if os.getenv('VGC_GROW_CHILD') != '' {
		println('GROW-DONE=${grow()}')
		return
	}
	mut off := run_child('0')
	mut on := run_child('')
	mut off_most := off.cycles
	for _ in 1 .. 3 {
		o := run_child('0')
		off_most = if o.cycles > off_most { o.cycles } else { off_most }
		off = least(off, o)
		on = least(on, run_child(''))
	}
	println('vgc_grow_gate_growing: gate off ${off.cycles}-${off_most} collections ${off.pause_us} us; default ${on.cycles} collections ${on.pause_us} us')
	assert off.cycles > 0
	assert on.cycles <= off_most, 'the gate added collections on a growing heap: ${on.cycles} against ${off.cycles}-${off_most} with the gate off'
	assert on.pause_us <= off.pause_us * 5 / 4 + 10000, 'the gate added pause time on a growing heap: ${on.pause_us} us against ${off.pause_us} us'
}
