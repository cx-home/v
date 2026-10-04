// vgc_refute_tiny_gate_test.v — the batch I-1 adversarial reader's two cases
// against the grow gate (e75b44db4; cx-private batch I-1, VGCG-1).
//
// 1. A tiny stream (n < 16, no-scan) is gated like any other: the tiny branch
//    of vgc_malloc_noscan_opts treated a nil span as "fall through" to the
//    size-class path, whose own span request then carved — the gate had
//    already fired for the cycle, so the deferral was spent with no collection
//    and the arenas reached the goal (2.01x, the same as with the gate off).
// 2. A malformed VGC_GROW_GATE_PCT keeps the default: atoll read `abc` and
//    `0x1e` as 0 and silently switched the gate off, while -1 and 101 kept it.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_refute_tiny_gate_test.v
module main

import os

const chunk = 4096
const live_bytes = 192 * 1024 * 1024
const carved_over_live_bound = 1.75

fn tiny_stream_ratio() f64 {
	mut live := [][]u8{cap: live_bytes / chunk}
	for _ in 0 .. live_bytes / chunk {
		live << []u8{len: chunk, init: 7}
	}
	// two collections that agree: the live set has stopped growing, the state the
	// gate serves (Letter 190: it stands down while the marked set still grows)
	gc_collect()
	gc_collect()
	marked := gc_heap_usage().total_bytes
	mut high := gc_memory_use()
	mut sink := u64(0)
	// 768 MB of tiny-block bytes: 16-byte blocks, two 8-byte objects each
	for i in 0 .. 4 * live_bytes / 8 {
		p := unsafe { &u64(malloc_noscan(8)) }
		unsafe {
			*p = u64(i)
		}
		sink += unsafe { *p }
		if i % 4096 == 0 {
			c := gc_memory_use()
			if c > high {
				high = c
			}
		}
	}
	assert live.len == live_bytes / chunk
	assert sink > 0
	return f64(high) / f64(marked)
}

fn test_a_tiny_stream_is_gated() {
	if os.getenv('VGC_REFUTE_CHILD') != '' {
		return // the child runs only the stream below
	}
	ratio := tiny_stream_ratio()
	println('vgc_refute_tiny_gate: tiny carved_over_live=${ratio:.3f} bound=${carved_over_live_bound}')
	assert ratio <= carved_over_live_bound, 'a tiny stream carved ${ratio:.3f}x its live set (bound ${carved_over_live_bound})'
}

// The child (this binary re-run with VGC_REFUTE_CHILD=1 and a malformed
// VGC_GROW_GATE_PCT) runs the 4 KB stream of vgc_grow_gate_test.v and prints
// its ratio; the gate must still be on.
fn test_a_malformed_gate_setting_keeps_the_default() {
	if os.getenv('VGC_REFUTE_CHILD') != '' {
		mut live := [][]u8{cap: live_bytes / chunk}
		for _ in 0 .. live_bytes / chunk {
			live << []u8{len: chunk, init: 7}
		}
		// two collections that agree: the live set has stopped growing, the state the
		// gate serves (Letter 190: it stands down while the marked set still grows)
		gc_collect()
		gc_collect()
		marked := gc_heap_usage().total_bytes
		mut high := gc_memory_use()
		mut sink := u64(0)
		for i in 0 .. 4 * live_bytes / chunk {
			t := []u8{len: chunk, init: u8(i)}
			sink += t[i % chunk]
			if i % 256 == 0 {
				c := gc_memory_use()
				if c > high {
					high = c
				}
			}
		}
		println('CHILD-RATIO=${f64(high) / f64(marked):.3f} sink=${sink} kept=${live.len}')
		return
	}
	for bad in ['abc', '0x1e', '', '30x'] {
		r := os.execute('VGC_REFUTE_CHILD=1 VGC_GROW_GATE_PCT="${bad}" ${os.quoted_path(os.executable())}')
		line := r.output.split_into_lines().filter(it.starts_with('CHILD-RATIO='))
		assert line.len == 1, 'the child printed no ratio for VGC_GROW_GATE_PCT="${bad}": ${r.output}'
		ratio := line[0].all_after('CHILD-RATIO=').all_before(' ').f64()
		println('vgc_refute_tiny_gate: VGC_GROW_GATE_PCT="${bad}" carved_over_live=${ratio:.3f}')
		assert ratio <= carved_over_live_bound, 'VGC_GROW_GATE_PCT="${bad}" switched the gate off (${ratio:.3f}x)'
	}
}
