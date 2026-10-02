// vgc_large_drop_test.v — a large transient a thread drops is reclaimed by the
// collections after it (cx-home/v#6, cx-private RTMEM-1's refutation read).
//
// Its own file, so its own process: a fresh heap, where the dropped buffer is
// the only large span and RSS moves by exactly its pages. Inside a file whose
// earlier test has built a 400 MB heap the reading is the earlier test's
// trimmed-pool history, not this buffer (measured: red on the pinned 77a460e26
// there too), so it cannot share one.
//
// Red on fefd75a56 (rss 66125824 -> 73170944: the buffer never swept), green on
// 77a460e26 and after (66 MB -> 10 MB).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_large_drop_test.v
module main

import runtime

// fill_and_drop allocates one large transient, touches every page, and drops
// it: the caller holds no reference once it returns.
@[noinline]
fn fill_and_drop(n int) int {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = 1
	}
	return b.len
}

// A large transient a thread drops must be reclaimed by the collections after
// it, whatever that thread allocates next. The acquisition stamp protects a
// span for the one sweep after it is handed out; an in-flight slot that held
// the thread's LAST large span until its NEXT large allocation kept a dropped
// 60 MB buffer unswept for the rest of a small-only build-up (the read:
// 2.40× → 2.79× peak over live). Two explicit collections return the pool to
// the OS, so the buffer's pages leave RSS if and only if it was swept.
fn test_a_dropped_large_buffer_is_reclaimed_by_the_next_collections() {
	n := 60 * 1024 * 1024
	assert fill_and_drop(n) == n
	held := runtime.used_memory() or { 0 }
	gc_collect()
	gc_collect()
	after := runtime.used_memory() or { 0 }
	println('vgc_monotone_retention: dropped_large held_rss=${held} after_two_collections=${after}')
	assert held > 0
	assert after + u64(n / 2) < held, 'a dropped ${n} B buffer stayed resident across two collections: rss ${held} -> ${after}'
}
