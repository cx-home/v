// vgc_frag_gate_growing_test.v — on a heap whose live set keeps growing, the
// #1892 frag gate adds no collections (cx-private #1914).
//
// The frag gate defers a new-arena carve to one defragmenting collection when
// the pool already holds twice the request. That pays in a steady loop (the
// json-codec parse/emit cycle), where the pool is the last cycle's garbage.
// While the live set still grows, the collection marks a set that is mostly
// live and moves the cycle's phase: `cx fmt` of an 8k-record document fired
// it right after the collection that marked its 264 MB tree, marked 257 MB
// again, and the shifted cycle landed the next collection on the formatter's
// 349 MB live peak — the pacer's goal went to 698 MB, peak RSS 616 -> 768 MB,
// wall 1.22 -> 1.45 s. The gate now asks the grow gate's question first
// (vgc_gate_early_while_growing): a growing set probes only at the cycle's
// last carve.
//
// Shape: a live set that grows to 192 MB in 2 KB records; each record is
// built beside a 3,000-byte transient of another size class (its spans empty
// out and pool between the records' spans: the pool fragments),
// and every 256 records a 1 MB transient buffer asks for a run of pages the
// fragmented pool cannot serve — the formatter's growing output buffer. The
// child runs with the frag gate at its default and off (VGC_FRAG_GATE=0),
// three times each, and counts the collections in VGC_GCTRACE. The default
// may take at most one collection in eight more than the gate off (a growing
// set still defragments at a cycle's last carve), and its total pause time
// no more than 1.25x the gate off's plus 10 ms (each the least of three runs).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frag_gate_growing_test.v
module main

import os

const rec = 2048
const live_bytes = 192 * 1024 * 1024
const big = 1024 * 1024
const scratch_len = 3000 // a size class of its own: its spans empty out and pool between the records'

fn grow() int {
	mut keep := [][]u8{cap: live_bytes / rec}
	mut sink := 0
	for i in 0 .. live_bytes / rec {
		a := []u8{len: 48, init: u8(i)}
		scratch := []u8{len: scratch_len, init: u8(i)}
		mut r := []u8{len: rec}
		r[0] = scratch[i % scratch_len] + a[i % 48]
		sink += r[0]
		keep << r
		if i % 256 == 255 {
			buf := []u8{len: big, init: u8(i)}
			sink += buf[i % big]
		}
	}
	return keep.len + sink % 2
}

struct Trace {
	cycles   int
	pause_us u64
}

fn run_child(gate string) Trace {
	env := if gate == '' { '' } else { 'VGC_FRAG_GATE=${gate} ' }
	r := os.execute('VGC_FRAG_CHILD=1 VGC_GCTRACE=1 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, 'the child failed (${gate}): ${r.output}'
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
	assert r.output.split_into_lines().any(it.starts_with('FRAG-DONE=')), 'the child printed no FRAG-DONE line: ${r.output}'
	return t
}

// least_of keeps the fewest collections and the least pause time over n runs:
// a loaded box can add a collection or stretch a pause, never take one away.
fn least_of(n int, gate string) Trace {
	mut best := run_child(gate)
	for _ in 1 .. n {
		t := run_child(gate)
		best = Trace{
			cycles:   if t.cycles < best.cycles { t.cycles } else { best.cycles }
			pause_us: if t.pause_us < best.pause_us { t.pause_us } else { best.pause_us }
		}
	}
	return best
}

fn test_a_growing_heap_takes_no_extra_frag_gate_collections() {
	if os.getenv('VGC_FRAG_CHILD') != '' {
		println('FRAG-DONE=${grow()}')
		return
	}
	off := least_of(3, '0')
	on := least_of(3, '')
	println('vgc_frag_gate_growing: gate off ${off.cycles} collections ${off.pause_us} us; default ${on.cycles} collections ${on.pause_us} us')
	assert off.cycles > 0
	// a growing set may still defragment at a cycle's last carve: at most one
	// collection in eight more than the gate off (measured: 17-18 against 17;
	// 65 against 18 before the guard)
	assert on.cycles <= off.cycles + off.cycles / 8, 'the frag gate added collections on a growing heap: ${on.cycles} against ${off.cycles} with the gate off'
	assert on.pause_us <= off.pause_us * 5 / 4 + 10000, 'the frag gate added pause time on a growing heap: ${on.pause_us} us against ${off.pause_us} us'
}
