// vgc_large_epoch_test.v — a large object born in an epoch and dropped in it
// is reclaimed by the sweep that ends that epoch (cx-home/v issue: the large
// path kept its acquisition stamp after the object was set up).
//
// vgc_alloc_large stamps its span sweep_gen = gc_cycle while the span is in
// flight to the allocating thread (vgc_sweep_span's guard), and the v#37
// in-flight claim drops once the object's address is in the caller's frame.
// The stamp stayed past that point, so the one sweep after the allocation
// skipped the span: every large transient of an epoch survived the collection
// that ended it, and the next epoch carved fresh arena pages beside it. A
// cache span drops the same stamp once its slot protects it (RTMEM-1,
// vgc_span_release_acquisition); a large object drops it with the claim.
// Measured on a 9 MB live set with one ~0.65 MB transient a loop: 34.0 MB RSS
// before, 23.7 MB after (cx-private#1935 json-codec, 1 MB parse/emit x100).
//
// Its own file, so its own process: a fresh heap, where the dropped buffer is
// the only large span and RSS moves by its pages (vgc_large_drop_test.v's
// reason). ONE explicit collection: it returns the pool to the OS
// (vgc_pool_trim_all), so the pages leave RSS if and only if that one sweep
// reclaimed the buffer.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_large_epoch_test.v
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

fn test_a_large_transient_is_reclaimed_by_the_sweep_that_ends_its_epoch() {
	n := 60 * 1024 * 1024
	assert fill_and_drop(n) == n
	held := runtime.used_memory() or { 0 }
	gc_collect()
	after := runtime.used_memory() or { 0 }
	println('vgc_large_epoch: held_rss=${held} after_one_collection=${after}')
	assert held > 0
	assert after + u64(n / 2) < held, 'a ${n} B buffer born and dropped in this epoch stayed resident across the collection that ended it: rss ${held} -> ${after}'
}
