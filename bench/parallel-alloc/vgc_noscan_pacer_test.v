// vgc_noscan_pacer_test.v — a stream of pointer-free allocations is paced:
// the heap collects at its goal instead of growing until span exhaustion
// (cx-private batch I-1, VGCG-1; the bar is 1226-a's 2.5× peak ÷ live).
//
// The scan allocation path checks the pacer (vgc_maybe_gc) once per filled
// span; the no-scan small path never did — only its > 32 KB branch did. Under
// 4660968c34 that was mostly strings; since cx-private #1629 every pointer-free
// array buffer is no-scan, so a []u8 / []int / strings.Builder stream never
// reached the trigger and the heap grew past its goal until a span request
// found no arena room and forced a collection. Measured on 62bcd55cf: a
// 192 MB live set followed by 768 MB of 4 KB []u8 transients carved 5.02× the
// live set with no collection after the first; with the check, the heap
// collects at its goal (2× the live set) and carves 2.03×.
//
// The arenas are read through gc_memory_use() (the bytes carved from them —
// never released, the RSS high-water a run cannot give back); no cx program
// can reach the allocator (the cx-gap note is in cx-private's batch I-1
// RESULTS.md).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_noscan_pacer_test.v
module main

const chunk = 4096
const live_bytes = 192 * 1024 * 1024 // L: three arenas of retained chunks
const churn_rounds = 4 // transients streamed: churn_rounds × L

// The goal is 2 × L at the default GOGC; the bar 1226-a holds peak ÷ live to.
const carved_over_live_bound = 2.5

fn test_a_pointer_free_stream_collects_at_its_goal() {
	mut live := [][]u8{cap: live_bytes / chunk}
	for _ in 0 .. live_bytes / chunk {
		live << []u8{len: chunk, init: 7}
	}
	gc_collect()
	marked := gc_heap_usage().total_bytes
	cycles0 := gc_heap_usage().bytes_since_gc // vgc reports its cycle count here
	mut high := gc_memory_use()
	mut sink := u64(0)
	for i in 0 .. churn_rounds * live_bytes / chunk {
		t := []u8{len: chunk, init: u8(i)}
		sink += t[i % chunk]
		if i % 256 == 0 {
			c := gc_memory_use()
			if c > high {
				high = c
			}
		}
	}
	cycles := gc_heap_usage().bytes_since_gc - cycles0
	ratio := f64(high) / f64(marked)
	println('vgc_noscan_pacer: live=${marked} carved_high=${high} carved_over_live=${ratio:.3f} cycles_during_stream=${cycles} bound=${carved_over_live_bound} sink=${sink} kept=${live.len}')
	assert live.len == live_bytes / chunk
	// 768 MB of transients over a 192 MB budget: the pacer collects at least
	// three times
	assert cycles >= 3, 'the pacer collected ${cycles} times during the stream'
	assert ratio <= carved_over_live_bound, 'the arenas reached ${ratio:.3f}× the live set during a pointer-free stream (bound ${carved_over_live_bound})'
}
