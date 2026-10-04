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
// it off (VGC_GROW_GATE_PCT=0) and counts the collections in VGC_GCTRACE. The
// gate at its default must take no more collections than the gate off, and
// its total pause time no more than 1.25x the gate off's plus 10 ms.
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

fn line_count_ok(out string) bool {
	return out.split_into_lines().any(it.starts_with('GROW-DONE='))
}

fn test_a_growing_heap_takes_no_extra_collections() {
	if os.getenv('VGC_GROW_CHILD') != '' {
		println('GROW-DONE=${grow()}')
		return
	}
	off := run_child('0')
	on := run_child('')
	println('vgc_grow_gate_growing: gate off ${off.cycles} collections ${off.pause_us} us; default ${on.cycles} collections ${on.pause_us} us')
	assert off.cycles > 0
	assert on.cycles <= off.cycles, 'the gate added collections on a growing heap: ${on.cycles} against ${off.cycles} with the gate off'
	assert on.pause_us <= off.pause_us * 5 / 4 + 10000, 'the gate added pause time on a growing heap: ${on.pause_us} us against ${off.pause_us} us'
}
