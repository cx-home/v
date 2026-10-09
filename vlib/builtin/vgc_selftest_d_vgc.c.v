module builtin

// vgc_residual4_selftest — deterministic, self-contained white-box self-check for the
// two load-bearing fixes to the multi-threaded-churn allocator bug (vgc_malloc returning
// NULL under heavy concurrent alloc/free -> `&T{}` null -> caller null-deref). It lives
// inside module builtin so it can reach the private span allocator + the mcache-protection
// pass; it is driven by bench/parallel-alloc/vgc_residual4_test.v (a module-main test —
// an in-builtin _test.v that references vgc symbols trips a `v test` double-compile of
// builtin). NOT @[markused]: no ordinary program calls it, so -skip-unused prunes it from
// production binaries; the test runner references it so it survives there. Only compiled
// under -d vgc / -gc e (the `_d_vgc` filename suffix). Returns 0 on success, else the id
// of the first failed check.
pub fn vgc_residual4_selftest() u32 {
	// ── Bug C ── vgc_span_alloc_obj's two-pass scan must cover the START byte's LOW
	// bits. The wrap pass used to re-apply the free_index start_bit offset to the start
	// byte, so a span with a free LOW slot but a high free_index (the fill-then-stale-
	// cross-thread-free state) reported "full" -> nil. Single-byte-bitmap spans hit it
	// whenever free_index == nelems.
	mut s := VGC_Span{
		base:      usize(0x100000)
		npages:    1
		elem_size: 16
		nelems:    4
		in_use:    true
	}
	s.alloc_bits = unsafe { &s.alloc_buf[0] }
	s.alloc_buf[0] = u8(0b00001101) // slots 0,2,3 allocated; slot 1 FREE
	s.alloc_count = 3
	s.free_index = 4 // past the free low slot
	p := unsafe { vgc_span_alloc_obj(mut s) }
	if p != unsafe { voidptr(s.base + usize(1) * usize(s.elem_size)) } {
		return 1 // pre-fix: returns nil (scan skipped bits [0,4) in both passes)
	}
	if s.alloc_count != 4 {
		return 2
	}
	// A genuinely full single-byte span must still report nil (no false positive).
	mut f := VGC_Span{
		base:      usize(0x200000)
		npages:    1
		elem_size: 16
		nelems:    4
		in_use:    true
	}
	f.alloc_bits = unsafe { &f.alloc_buf[0] }
	f.alloc_buf[0] = u8(0b00001111)
	f.alloc_count = 4
	f.free_index = 4
	if unsafe { vgc_span_alloc_obj(mut f) } != unsafe { nil } {
		return 3
	}

	// ── Bug B ── vgc_protect_cached_spans must stamp every mcache-RESIDENT span's
	// sweep_gen with the current gc_cycle so this cycle's sweep skips it (else an empty
	// cached span is reclaimed + zeroed by vgc_put_free_span while a suspended owner
	// still references it -> nelems=0 -> nil -> null-deref). A span NOT in any cache
	// must be left alone (so genuinely-dead spans still reclaim).
	idx := C.vgc_get_cache_idx()
	if idx < 0 {
		return 4 // self-check thread must be vgc-registered
	}
	// No allocation happens between vgc_span_alloc and vgc_put_free_span below, and
	// vgc_span_alloc never triggers a collection, so single-threaded no real GC fires
	// in this window to race our scratch spans — no collector-pin needed.
	class_idx := u8(C.vgc_size_class(u32(64)))
	sc := int(class_idx) * 2 // scan variant
	np := u32(C.vgc_get_class_npages(int(class_idx)))
	mut span := vgc_span_alloc(np)
	if span == unsafe { nil } {
		return 5
	}
	unsafe { vgc_span_init(mut span, class_idx, false) }
	old_gen := u32(vgc_heap.gc_cycle)
	span.alloc_count = 0 // empty -> reclaim-eligible
	span.sweep_gen = old_gen - 1 // stale -> WOULD be reclaimed without the stamp
	// install in THIS thread's mcache slot (save + restore; no allocation in the window)
	saved_slot := unsafe { vgc_heap.caches[idx].alloc[sc] }
	unsafe {
		vgc_heap.caches[idx].alloc[sc] = span
	}
	vgc_protect_cached_spans()
	stamped := span.sweep_gen
	unsafe {
		vgc_heap.caches[idx].alloc[sc] = saved_slot
	}
	mut rc := u32(0)
	if stamped != u32(vgc_heap.gc_cycle) {
		rc = 6 // resident span was NOT protected (pre-fix)
	}
	// negative control: a span referenced by no cache slot must NOT be stamped
	mut span2 := vgc_span_alloc(np)
	if span2 != unsafe { nil } {
		unsafe { vgc_span_init(mut span2, class_idx, false) }
		span2.sweep_gen = old_gen - 7
		vgc_protect_cached_spans()
		if rc == 0 && span2.sweep_gen != old_gen - 7 {
			rc = 7
		}
		unsafe { vgc_put_free_span(mut span2) }
	}
	unsafe { vgc_put_free_span(mut span) }
	return rc
}

// vgc_rtmem_compensation_stats — white-box readings for
// bench/parallel-alloc/vgc_monotone_retention_test.v (RTMEM-1): the page-map
// slots vgc_pool_compensate has visited so far, the collection count, and the
// pages the arenas have carved now. Same posture as vgc_residual4_selftest: no
// ordinary program calls it, so -skip-unused prunes it.
pub fn vgc_rtmem_compensation_stats() (u64, u64, u64) {
	C.vgc_mutex_lock(&vgc_heap.free_spans_lock)
	scanned := vgc_compensate_scanned
	C.vgc_mutex_unlock(&vgc_heap.free_spans_lock)
	mut pages := u64(0)
	for i in 0 .. vgc_heap.narenas {
		pages += u64(vgc_heap.arenas[i].used / vgc_page_size)
	}
	return scanned, vgc_heap.gc_cycle, pages
}

// vgc_pool_aged_selftest — white-box check of vgc_pool_push_aged for
// bench/parallel-alloc/vgc_pool_push_aged_test.v (cx-home/v#11). On one
// otherwise unused hot chain (npages 8191, saved and restored around the run,
// under free_spans_lock, gc_cycle pinned at 100) it files `n` descriptors in
// the churn shape of pi-digits: each round a plain push (this cycle's span),
// an aged push of the previous cycle's gen, and one of an old-enough gen. It
// answers (rc, ns): rc 0 when the chain then reads, head to tail, as the
// trim needs it — the young spans (cyc - gen < vgc_pool_trim_age) in
// non-increasing gen order, then only old-enough spans, prev/next and the
// tail consistent and every span on it; ns is the filing time alone.
pub fn vgc_pool_aged_selftest(n int) (u32, u64) {
	np := u32(8191)
	descs := unsafe { &VGC_Span(C.calloc(usize(n), sizeof(VGC_Span))) }
	if descs == unsafe { nil } {
		return 1, 0
	}
	C.vgc_mutex_lock(&vgc_heap.free_spans_lock)
	saved_head := vgc_heap.free_spans[np]
	saved_tail := vgc_heap.free_spans_tail[np]
	saved_mark0 := vgc_heap.free_spans_aged_mark[int(np) * 2]
	saved_mark1 := vgc_heap.free_spans_aged_mark[int(np) * 2 + 1]
	saved_bytes := vgc_heap.pool_bytes
	saved_cycle := vgc_heap.gc_cycle
	vgc_heap.free_spans[np] = unsafe { nil }
	vgc_heap.free_spans_tail[np] = unsafe { nil }
	vgc_heap.free_spans_aged_mark[int(np) * 2] = unsafe { nil }
	vgc_heap.free_spans_aged_mark[int(np) * 2 + 1] = unsafe { nil }
	vgc_heap.gc_cycle = 100
	cyc := u32(100)
	t0 := C.vgc_now_ns()
	for i in 0 .. n {
		mut d := unsafe { &descs[i] }
		d.npages = np
		match i % 4 {
			0 { vgc_pool_push(mut d) }
			1 { vgc_pool_push_aged(mut d, cyc - 1) }
			2 { vgc_pool_push_aged(mut d, cyc) }
			else { vgc_pool_push_aged(mut d, cyc - 2 - u32(i % 5)) }
		}
	}
	elapsed := C.vgc_now_ns() - t0
	mut rc := u32(0)
	mut seen := 0
	mut prev := unsafe { &VGC_Span(nil) }
	mut last_young_gen := cyc
	mut in_old := false
	mut s := vgc_heap.free_spans[np]
	for s != unsafe { nil } {
		if voidptr(s.prev) != voidptr(prev) {
			rc = 2
			break
		}
		young := cyc - s.pool_gen < vgc_pool_trim_age
		if young {
			if in_old {
				rc = 3 // a young span tailward of an old-enough one: the trim stops short
				break
			}
			if s.pool_gen > last_young_gen {
				rc = 4 // young spans out of age order
				break
			}
			last_young_gen = s.pool_gen
		} else {
			in_old = true
		}
		seen++
		prev = s
		s = s.next
	}
	if rc == 0 && voidptr(vgc_heap.free_spans_tail[np]) != voidptr(prev) {
		rc = 5
	}
	if rc == 0 && seen != n {
		rc = 6
	}
	vgc_heap.free_spans[np] = saved_head
	vgc_heap.free_spans_tail[np] = saved_tail
	vgc_heap.free_spans_aged_mark[int(np) * 2] = saved_mark0
	vgc_heap.free_spans_aged_mark[int(np) * 2 + 1] = saved_mark1
	vgc_heap.pool_bytes = saved_bytes
	vgc_heap.gc_cycle = saved_cycle
	C.vgc_mutex_unlock(&vgc_heap.free_spans_lock)
	unsafe { C.free(descs) }
	return rc, elapsed
}
