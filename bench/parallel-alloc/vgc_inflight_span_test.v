// vgc_inflight_span_test.v — cx-home/v#37: a span in flight to its owner (popped
// from central.partial, or fresh from the pool, and not yet in the owner's mcache
// slot) must survive any number of collections off every list: the acquisition
// stamp covered one sweep, so an owner off-CPU across a whole cycle (the 4-vCPU
// runner under the walks-forced vgc_concurrent_cached_span_test) came back to a
// span the next sweep had relinked onto central.partial — a second thread popped
// it, the owner filled it, the second thread's vgc_span_alloc_obj answered nil
// ('malloc_noscan(0x10) V panic: memory allocation failure') — or recycled to the
// pool (a fresh span's pages handed out twice: the bad=1 checksum reds). The
// white-box self-check in module builtin (vgc_inflight_selftest) drives exactly
// that window on one thread: the span is held in a local across two gc_collect()
// calls. Deterministic: 5/8 on 3b3fd54ba1, 0 with the in-flight claim bit.
//
//   ./v -gc e -cc cc test bench/parallel-alloc/vgc_inflight_span_test.v
module main

fn test_vgc_span_in_flight_survives_the_sweep() {
	rc := vgc_inflight_selftest()
	// 0 = ok; 5 = a popped partial span relinked while in flight; 6 = recycled;
	// 8 = a fresh span recycled while in flight; 1-4, 7 = setup preconditions.
	assert rc == 0, 'vgc_inflight_selftest rc=${rc}'
}
