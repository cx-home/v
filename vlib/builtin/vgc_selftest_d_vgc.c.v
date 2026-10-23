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
	saved_slot := unsafe { vgc_cache(idx).alloc[sc] }
	unsafe {
		vgc_cache(idx).alloc[sc] = span
	}
	vgc_protect_cached_spans()
	stamped := span.sweep_gen
	unsafe {
		vgc_cache(idx).alloc[sc] = saved_slot
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
// vgc_pool_aged_selftest_steps answers the walk steps the last
// vgc_pool_aged_selftest run took (cx-home/v#54).
pub fn vgc_pool_aged_selftest_steps() u64 {
	return vgc_pool_aged_steps
}

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
	vgc_pool_aged_steps = 0
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

// vgc_inflight_selftest — cx-home/v#37: a span IN FLIGHT to its owner — popped
// from central.partial, or fresh from the pool, and not yet stored into the
// owner's mcache slot (the line after vgc_central_get_span returns in
// vgc_cache_get_span) — is referenced by nothing the collector reads. The
// acquisition stamp (sweep_gen = gc_cycle) covered exactly one sweep, so an
// owner off-CPU across a whole cycle (a 4-vCPU runner, 25 runnable threads, a
// forced cycle every 2 ms) came back to a span the next sweep had RELINKED
// onto central.partial (a partial span: a second thread popped it, the owner
// filled it, the second thread's vgc_span_alloc_obj answered nil — the
// walks-forced 'malloc_noscan(0x10) V panic: memory allocation failure') or
// RECYCLED to the pool (a fresh span: its pages handed out twice — the bad=1
// checksum mismatches). This drives exactly that window on the calling
// thread, with no load lottery: the span is held in a local across two
// collections and must still be off every list and in use afterwards. The
// in-flight claim bit (VGC_Span.inflight) is what keeps it so. Driven by
// bench/parallel-alloc/vgc_inflight_span_test.v. Returns 0, else the id of the
// first failed check (1-4, 7 = setup preconditions).
pub fn vgc_inflight_selftest() u32 {
	idx := C.vgc_get_cache_idx()
	if idx < 0 {
		return 1 // the calling thread must be vgc-registered
	}
	class_idx := u8(C.vgc_size_class(u32(24)))
	sc := int(class_idx) * 2 + 1 // noscan variant: the fixture's dying class
	np := u32(C.vgc_get_class_npages(int(class_idx)))
	mut rc := u32(0)
	// (a) a PARTIAL span: one object carved, listed on central.partial the way
	// the sweep lists it, popped as vgc_cache_get_span pops it, and held here
	// — not in any mcache slot — across two collections.
	mut s := vgc_span_alloc(np)
	if s == unsafe { nil } {
		return 2
	}
	unsafe { vgc_span_init(mut s, class_idx, true) }
	p := unsafe { vgc_span_alloc_obj(mut s) }
	if p == unsafe { nil } {
		return 3
	}
	vgc_inflight_keep = usize(p) // a data-segment root: the object stays live
	central := unsafe { &vgc_heap.central[sc] }
	C.vgc_mutex_lock(&central.lock)
	unsafe {
		s.next = central.partial
		s.prev = nil
		if s.next != nil {
			s.next.prev = s
		}
		vgc_heap.central[sc].partial = s
		s.on_central = 1
	}
	C.vgc_mutex_unlock(&central.lock)
	got := vgc_central_get_span(sc)
	if unsafe { voidptr(got) } != unsafe { voidptr(s) } {
		return 4 // another thread took it: no verdict
	}
	gc_collect()
	gc_collect()
	if s.on_central != 0 {
		rc = 5 // relinked while in flight (3b3fd54ba1: the second sweep)
	} else if !s.in_use {
		rc = 6 // recycled while in flight
	}
	if rc == 0 {
		// the owner's side of the hand-over, as vgc_cache_get_span does it:
		// the slot store, then the stamp and the claim bit released
		saved := unsafe { vgc_cache(idx).alloc[sc] }
		unsafe {
			vgc_cache(idx).alloc[sc] = s
		}
		vgc_span_release_acquisition(s)
		unsafe {
			vgc_cache(idx).alloc[sc] = saved
		}
	}
	vgc_inflight_keep = 0
	// (b) a FRESH span (alloc_count 0) held across two collections.
	mut f := vgc_span_alloc(np)
	if f == unsafe { nil } {
		return 7
	}
	unsafe { vgc_span_init(mut f, class_idx, true) }
	gc_collect()
	gc_collect()
	if !f.in_use {
		if rc == 0 {
			rc = 8 // recycled while in flight (3b3fd54ba1: the second sweep)
		}
	} else {
		vgc_span_release_acquisition(f)
		C.vgc_mutex_lock(&vgc_heap.free_spans_lock)
		unsafe { vgc_put_free_span(mut f) }
		C.vgc_mutex_unlock(&vgc_heap.free_spans_lock)
	}
	return rc
}

// vgc_mark_backoff_selftest — cx-home/v#52: the marker plan's back-off
// (vgc_mark_adapt) must end. It counted down only on parallel cycles, so a
// probe halved to ONE marker never ran another parallel cycle and stayed on
// one marker for the rest of the process (the stores-mt driver at eight
// threads in three runs of five: 570 ms against 220). The adapt function is
// driven with synthetic cycles of the concurrent kind on the calling thread
// (the caller runs no collection meanwhile) and every global it touches is
// restored. Driven by bench/parallel-alloc/vgc_mark_backoff_test.v. Returns 0,
// else the id of the first failed check.
pub fn vgc_mark_backoff_selftest() u32 {
	$if !vgc_concurrent ? {
		return 0
	} $else {
		s_ncur := vgc_mark_nworkers_cur
		s_last := vgc_mark_last_ns
		s_r1 := vgc_mark_rate1
		s_r1cm := vgc_mark_rate1_cm
		s_tgt := vgc_mark_n_target
		s_bo := vgc_mark_backoff
		s_lost := vgc_mark_lost_rate
		s_lostcm := vgc_mark_lost_cm
		s_cm := vgc_cm_this_cycle
		mut rc := u32(0)
		kb := u64(20000) // marked = 20000 KB less a byte: kb = marked / 1024 + 1
		marked := (kb - 1) * 1024
		vgc_cm_this_cycle = true
		// (1) a two-marker probe at 160 ns/KB against a 145 baseline loses:
		// one marker, a 32-cycle back-off
		vgc_mark_rate1_cm = 145
		vgc_mark_n_target = 0
		vgc_mark_backoff = 0
		vgc_mark_lost_rate = 0
		vgc_mark_nworkers_cur = 2
		vgc_mark_last_ns = 160 * kb
		vgc_mark_adapt(marked)
		if vgc_mark_n_target != 1 || vgc_mark_backoff != 32 {
			rc = 1
		}
		// (2) the one-marker cycles of the back-off read 290 ns/KB: the
		// baseline passes the probe's rate within a few cycles and the
		// back-off ends (the probe won after all)
		if rc == 0 {
			vgc_mark_nworkers_cur = 1
			vgc_mark_last_ns = 290 * kb
			mut ended := 0
			for i in 0 .. 8 {
				vgc_mark_adapt(marked)
				if vgc_mark_n_target == 0 && vgc_mark_backoff == 0 {
					ended = i + 1
					break
				}
			}
			if ended == 0 {
				rc = 2
			}
		}
		// (3) a probe that truly lost (the one-marker rate stays at the
		// baseline): the back-off still ends after its 32 cycles, not never
		if rc == 0 {
			vgc_mark_rate1_cm = 145
			vgc_mark_n_target = 0
			vgc_mark_backoff = 0
			vgc_mark_nworkers_cur = 2
			vgc_mark_last_ns = 160 * kb
			vgc_mark_adapt(marked)
			vgc_mark_nworkers_cur = 1
			vgc_mark_last_ns = 145 * kb
			for _ in 0 .. 31 {
				vgc_mark_adapt(marked)
			}
			if vgc_mark_n_target != 1 || vgc_mark_backoff != 1 {
				rc = 3 // ended early on a probe that lost, or counted no cycle
			} else {
				vgc_mark_adapt(marked)
				if vgc_mark_n_target != 0 || vgc_mark_backoff != 0 {
					rc = 4 // the 32nd one-marker cycle did not end it
				}
			}
		}
		vgc_mark_nworkers_cur = s_ncur
		vgc_mark_last_ns = s_last
		vgc_mark_rate1 = s_r1
		vgc_mark_rate1_cm = s_r1cm
		vgc_mark_n_target = s_tgt
		vgc_mark_backoff = s_bo
		vgc_mark_lost_rate = s_lost
		vgc_mark_lost_cm = s_lostcm
		vgc_cm_this_cycle = s_cm
		return rc
	}
}

// vgc_mark_cpu_plan_selftest — cx-home/v#55: a one-marker mark the box slowed
// down (5 ms of wall, 0.5 ms of the collecting thread's CPU) plans on its CPU
// time, so the next cycle stays on one marker; a mark whose CPU matches its
// wall (a large single process) still reaches the pool; a parallel mark keeps
// its n x wall estimate. Globals restored. Driven by
// bench/parallel-alloc/vgc_mark_cpu_plan_test.v. 0, else the failed check.
pub fn vgc_mark_cpu_plan_selftest() u32 {
	s_ncur := vgc_mark_nworkers_cur
	s_work := vgc_mark_last_work_ns
	s_cpu := vgc_mark_last_cpu_ns
	mut rc := u32(0)
	ms := u64(1000000)
	vgc_mark_nworkers_cur = 1
	vgc_mark_last_work_ns = 5 * ms
	vgc_mark_work_from_cpu_at(1000, 0, 1000 + ms / 2, 0)
	if vgc_mark_last_work_ns != ms / 2 {
		rc = 1
	}
	if rc == 0 {
		// the waits the cycle spun are not work
		vgc_mark_last_work_ns = 5 * ms
		vgc_mark_work_from_cpu_at(1000, 0, 1000 + 3 * ms, 2 * ms)
		if vgc_mark_last_work_ns != ms {
			rc = 2
		}
	}
	if rc == 0 {
		// CPU close to wall: the wall stays the estimate
		vgc_mark_last_work_ns = 5 * ms
		vgc_mark_work_from_cpu_at(1000, 0, 1000 + 6 * ms, 0)
		if vgc_mark_last_work_ns != 5 * ms {
			rc = 3
		}
	}
	if rc == 0 {
		// a parallel mark is untouched
		vgc_mark_nworkers_cur = 4
		vgc_mark_last_work_ns = 8 * ms
		vgc_mark_work_from_cpu_at(1000, 0, 1000 + ms / 2, 0)
		if vgc_mark_last_work_ns != 8 * ms {
			rc = 4
		}
	}
	vgc_mark_nworkers_cur = s_ncur
	vgc_mark_last_work_ns = s_work
	vgc_mark_last_cpu_ns = s_cpu
	return rc
}

// vgc_uaf_foreign_selftest — cx-private#2011. The passive UAF oracle
// (vgc_uaf_check_buf) bounds an address by [vgc_arena_lo, vgc_arena_hi), the
// span of the arenas. On Linux glibc's per-thread malloc arenas are mmaps that
// land inside that span, so a libc buffer between two arenas read as "span
// recycled/decommitted" (0xbf3 = 0xdec0): the concurrency-soundness gate's
// first Linux run counted ~2,000 such catches on the HTTP stressors, every one
// a clone of picoev's C.malloc'd request buffer. This plants that shape with
// no threads: a C.malloc'd buffer, the arena bounds widened over it, and the
// oracle must answer "not a vgc free" without counting a catch. A buffer vgc
// itself freed must still be caught. Driven by
// bench/parallel-alloc/vgc_uaf_foreign_test.v. 0 = ok; 1 = setup (the libc
// buffer is inside an arena); 2 = the foreign address read as freed (the old
// check); 3 = a vgc-freed buffer was not caught.
pub fn vgc_uaf_foreign_selftest() u32 {
	foreign := unsafe { C.malloc(64) }
	f := usize(foreign)
	if vgc_addr_in_arena(f) {
		unsafe { C.free(foreign) }
		return 1
	}
	lo := vgc_arena_lo
	hi := vgc_arena_hi
	if f < vgc_arena_lo {
		vgc_arena_lo = f
	}
	if f + 64 > vgc_arena_hi {
		vgc_arena_hi = f + 64
	}
	count0 := vgc_uaf_count
	caught := vgc_uaf_check_buf(f, 8)
	vgc_arena_lo = lo
	vgc_arena_hi = hi
	unsafe { C.free(foreign) }
	if caught || vgc_uaf_count != count0 {
		return 2
	}
	p := unsafe { malloc_noscan(32) }
	vgc_free(p)
	if !vgc_uaf_check_buf(usize(p), 8) {
		return 3
	}
	return 0
}
