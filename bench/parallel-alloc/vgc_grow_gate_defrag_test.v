// vgc_grow_gate_defrag_test.v — a large request that the GROW gate defers is
// served from the pool's adjacent free spans, not a fresh arena
// (cx-home/v#12, the cx side of cx-private#1892).
//
// Two gates defer a new-arena carve to one collection: the grow gate (the
// heap is most of the way from the marked set to its goal) and the frag gate
// (the pool holds the request's pages, but not as one run; its collection
// merges adjacent pooled spans, vgc_pool_defrag). vgc_span_alloc tries them in
// that order, and the retry after the collection runs inside the
// reclaim-and-retry loop (vgc_grow_gate_hold), where neither gate fires. So a
// grow-gate deferral's collection did not defragment, and its retry carved: a
// json-codec 1 MB loop carved a third 64 MB arena for a 65-page emitter buffer
// while 1,107 pages of 14-page free spans lay side by side in the first arena.
// Which iteration met that state depended on the iteration count and on the
// binary's start-up heap, so the process peak stepped by ~50 MB
// (cx-private#1892: 144-152 MB at most N, 198-208 MB at N = 40/60/80/200).
//
// The rule under test: a grow-gate deferral whose request the pool could hold
// also defragments in its collection. Shape: a small retained set, then 1 KB
// objects dropped (the pool: tens of MB of one-page spans side by side), a
// retained filler to the end of the last arena; the heap's headroom is learned from one natural collection; transients take the
// heap past the grow gate's fraction of that headroom; then one large request
// that neither a pooled span nor an arena tail holds. The arenas' carved bytes
// (gc_memory_use) must not grow by the request.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_grow_gate_defrag_test.v
module main

const small = 1024
const keep_bytes = 2 * 1024 * 1024
const drop_bytes = 40 * 1024 * 1024
const arena = 64 * 1024 * 1024
const tail_max = 4 * 1024 * 1024
const big = 8 * 1024 * 1024 // 1,024 pages: past any size-class span and the arena tail

struct Hold {
mut:
	keep [][]u8
	ring [][]u8
	n    int
}

fn drop_fill(mut h Hold) {
	mut drop := [][]u8{cap: drop_bytes / small}
	for i in 0 .. drop_bytes / small {
		drop << []u8{len: small, init: u8(i)}
	}
	h.n += drop.len
}

// transient allocates `bytes` of 1 KB garbage (a short ring keeps the
// compiler from eliding it).
fn transient(mut h Hold, bytes int) {
	for i in 0 .. bytes / small {
		h.ring[i % h.ring.len] = []u8{len: small, init: u8(i)}
	}
}

fn test_a_grow_gate_deferral_defragments_before_a_new_arena() {
	mut h := Hold{
		ring: [][]u8{len: 64}
	}
	for i in 0 .. keep_bytes / small {
		h.keep << []u8{len: small, init: u8(i)}
	}
	drop_fill(mut h)
	// retained filler until the last arena's uncarved tail is under tail_max,
	// so the large request below fits no arena tail
	for (arena - int(gc_memory_use() % usize(arena))) >= tail_max {
		h.keep << []u8{len: small, init: 1}
	}
	gc_collect()
	gc_collect()
	// learn the headroom: transients until a collection resets bytes_since_gc
	mut learned := 0
	mut last := gc_heap_usage().bytes_since_gc
	for learned < 512 * 1024 * 1024 {
		transient(mut h, 256 * 1024)
		learned += 256 * 1024
		now := gc_heap_usage().bytes_since_gc
		if now < last {
			break
		}
		last = now
	}
	// past the grow gate's 30 % of the goal's headroom, short of the goal
	transient(mut h, learned * 6 / 10)
	carved0 := gc_memory_use()
	b := []u8{len: big, init: 7}
	carved1 := gc_memory_use()
	grew := i64(carved1) - i64(carved0)
	println('vgc_grow_gate_defrag: headroom~${learned} kept=${h.keep.len} carved_before=${carved0} carved_after=${carved1} grew=${grew} (n=${h.n} b=${b.len})')
	assert grew < big, 'a ${big}-byte request carved ${grew} new bytes with ${drop_bytes} bytes of adjacent free 1 KB spans pooled'
}
