// vgc_grow_gate_test.v — the heap does not take a new arena for the last
// stretch of a cycle's growth when a collection would serve it
// (cx-private batch I-1, VGCG-1; the bar is 1226-a's 2.5× peak ÷ live).
//
// vgc lets the heap reach its goal, marked × (1 + GOGC/100), before it
// collects, and an arena it carves on the way is never released. When the
// growth that a cycle still has to make does not fit the arenas already
// carved, the pacer used to carve a fresh 64 MB arena even with the goal all
// but reached — and the cycle's garbage, freed a moment later, then sat
// pooled beside it. Which cycle lands on an arena boundary is a phase of the
// workload: cx's 300k-record JSON convert read 2.49× peak RSS ÷ marked on
// 4660968c34 and 2.68× on 62bcd55cf (one arena more, the same live set), and
// a sweep of the first trigger moved both between 2.2× and 2.7×.
//
// The rule under test: carving a NEW arena while the heap holds at least
// vgc_grow_gate_pct of its goal is deferred to one collection first (at most
// once per cycle), so the collection's garbage serves the growth from the
// arenas the heap already has. Shape: a retained live set L, then a stream of
// transients several times L. Without the gate the arenas' high-water reaches
// the goal, 2 × L; with it the high-water stays near the gate's fraction of
// the goal. Measured: 5.02× on 62bcd55cf (the no-scan stream never reached
// the pacer — vgc_noscan_pacer_test.v), 2.03× with the pacer's check alone,
// 1.39× with the gate.
//
// The allocator's arena accounting is read through gc_memory_use() (the bytes
// carved from the arenas, the RSS high-water a run cannot give back); no cx
// program can reach it (the cx-gap note is in cx-private's batch I-1
// RESULTS.md).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_grow_gate_test.v
module main

const chunk = 4096
const live_bytes = 192 * 1024 * 1024 // L: three arenas of retained chunks
const churn_rounds = 4 // transients streamed: churn_rounds × L

// The arenas' high-water over the live set L. Without the gate it reaches
// the goal (2 × L) plus a partial arena; the gate keeps it under this.
const carved_over_live_bound = 1.75

fn test_the_heap_collects_before_it_carves_an_arena_near_its_goal() {
	mut live := [][]u8{cap: live_bytes / chunk}
	for _ in 0 .. live_bytes / chunk {
		live << []u8{len: chunk, init: 7}
	}
	gc_collect()
	marked := gc_heap_usage().total_bytes
	carved0 := gc_memory_use()
	mut high := carved0
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
	ratio := f64(high) / f64(marked)
	println('vgc_grow_gate: live=${marked} carved_before_churn=${carved0} carved_high=${high} carved_over_live=${ratio:.3f} bound=${carved_over_live_bound} sink=${sink} kept=${live.len}')
	assert live.len == live_bytes / chunk
	assert ratio <= carved_over_live_bound, 'the arenas reached ${ratio:.3f}× the live set during a stream of transients (bound ${carved_over_live_bound})'
}
