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
	saved_k := vgc_pool_kind_save(np)
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
	vgc_pool_kind_restore(np, saved_k)
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

// vgc_arena_owner_selftest — cx-examples#403. A new span comes off the tail of
// an arena no other live thread carves (vgc_arena_pick), on a table of four
// 64-page arenas: one thread carves first fit; a live thread's arena is passed
// over and a free one claimed (the claimer's previous arena released); an
// exited thread's arena is claimed; only another live thread's tail left maps
// a new arena below the ceiling and is carved at it; the rule off is first fit;
// an owner that carved none of its tail in this completed cycle or the last
// holds it no more (cases 10-15).
// Driven by bench/parallel-alloc/vgc_arena_owner_test.v. 0 = ok; n = the case.
__global vgc_arena_selftest_exited = int(0)

fn vgc_arena_selftest_live(o int) bool {
	return o >= 1 && o <= 4 && o != vgc_arena_selftest_exited
}

pub fn vgc_arena_owner_selftest() u32 {
	sz := usize(64) * vgc_page_size
	vgc_arena_selftest_exited = 0
	mut t := [4]VGC_Arena{}
	for i in 0 .. 4 {
		t[i].base = usize(i + 1) * sz
		t[i].size = sz
	}
	pg := usize(vgc_page_size)
	// one thread (owner 1 or none everywhere): first fit, as before
	t[0].used = sz
	if vgc_arena_pick(pg, 1, 4, &t[0], 1024, vgc_arena_selftest_live, 10, vgc_kind_plain) != 1
		|| t[1].owner != 1 {
		return 1
	}
	// thread 2 (live) passes over thread 1's arena 1 and claims arena 2
	if vgc_arena_pick(pg, 2, 4, &t[0], 1024, vgc_arena_selftest_live, 10, vgc_kind_plain) != 2
		|| t[2].owner != 2 {
		return 2
	}
	// thread 2's next carve stays in its own arena even with arena 1 first
	if vgc_arena_pick(pg, 2, 4, &t[0], 1024, vgc_arena_selftest_live, 10, vgc_kind_plain) != 2 {
		return 3
	}
	// thread 2 claims arena 3 once arena 2 is full, releasing arena 2
	t[2].used = sz
	if vgc_arena_pick(pg, 2, 4, &t[0], 1024, vgc_arena_selftest_live, 10, vgc_kind_plain) != 3
		|| t[3].owner != 2 || t[2].owner != 0 {
		return 4
	}
	// thread 1 exits; thread 3 claims its arena 1
	vgc_arena_selftest_exited = 1
	if vgc_arena_pick(pg, 3, 4, &t[0], 1024, vgc_arena_selftest_live, 10, vgc_kind_plain) != 1
		|| t[1].owner != 3 {
		return 5
	}
	// thread 4: every tail left is a live thread's (1: thread 3, 3: thread 2) — map a new arena
	if vgc_arena_pick(pg, 4, 4, &t[0], 1024, vgc_arena_selftest_live, 10, vgc_kind_plain) != -1 {
		return 6
	}
	// ... unless the table is at the ceiling: the first tail with room
	if vgc_arena_pick(pg, 4, 4, &t[0], 5, vgc_arena_selftest_live, 10, vgc_kind_plain) != 1
		|| t[1].owner != 3 {
		return 7
	}
	// the rule off (me 0): first fit across owners
	if vgc_arena_pick(pg, 0, 4, &t[0], 1024, vgc_arena_selftest_live, 10, vgc_kind_plain) != 1 {
		return 8
	}
	// a request no tail holds
	if vgc_arena_pick(sz + pg, 0, 4, &t[0], 1024, vgc_arena_selftest_live, 10, vgc_kind_plain) != -1 {
		return 9
	}
	// an owner holds its tail only while it carves (vgc_arena_owner_cycles = 1):
	// thread 1 carved arena 0 at start-up (cycle 0) and waits; thread 2 works
	mut u := [2]VGC_Arena{}
	for i in 0 .. 2 {
		u[i].base = usize(i + 1) * sz
		u[i].size = sz
	}
	vgc_arena_selftest_exited = 0
	u[0].owner = 1
	u[0].used = pg
	u[0].carve_cycle = 0
	u[1].owner = 2
	u[1].used = sz
	u[1].carve_cycle = 1
	// in the next cycle thread 1's carve is the last cycle's: a new arena
	if vgc_arena_pick(pg, 2, 2, &u[0], 1024, vgc_arena_selftest_live, 1, vgc_kind_plain) != -1
		|| u[0].owner != 1 {
		return 10
	}
	// a cycle later thread 1 carves no more: thread 2 claims arena 0
	if vgc_arena_pick(pg, 2, 2, &u[0], 1024, vgc_arena_selftest_live, 2, vgc_kind_plain) != 0
		|| u[0].owner != 2 || u[0].carve_cycle != 2 || u[1].owner != 0 {
		return 11
	}
	// thread 1 wakes in the same cycle: thread 2 carved there now
	if vgc_arena_pick(pg, 1, 2, &u[0], 1024, vgc_arena_selftest_live, 2, vgc_kind_plain) != -1
		|| u[0].owner != 2 {
		return 12
	}
	// thread 2's own carve keeps it: carving at cycle 5 holds it through cycle 6
	if vgc_arena_pick(pg, 2, 2, &u[0], 1024, vgc_arena_selftest_live, 5, vgc_kind_plain) != 0
		|| u[0].carve_cycle != 5 {
		return 13
	}
	if vgc_arena_pick(pg, 1, 2, &u[0], 1024, vgc_arena_selftest_live, 6, vgc_kind_plain) != -1 {
		return 14
	}
	// the rule off (me 0) is first fit and stamps no carve
	if vgc_arena_pick(pg, 0, 2, &u[0], 1024, vgc_arena_selftest_live, 9, vgc_kind_plain) != 0
		|| u[0].carve_cycle != 5 {
		return 15
	}
	return 0
}

// vgc_mark_wide_selftest — cx-examples#403. A stop that holds more mutators
// than the configured markers fields one marker per CPU the box leaves free, up
// to one per held mutator plus the collector and at most vgc_max_markers; a
// busy box (0 free), a stop of few mutators and a box of few CPUs keep the
// configured count. Driven by bench/parallel-alloc/vgc_mark_wide_test.v.
// 0 = ok; n = the failed case.
pub fn vgc_mark_wide_selftest() u32 {
	// 28 parses on 28 free CPUs: 28 markers, not the configured 8
	if vgc_mark_wide_total(8, 28, 28) != 28 {
		return 1
	}
	// one per held mutator plus the collector
	if vgc_mark_wide_total(8, 12, 28) != 13 {
		return 2
	}
	// the box's other load takes CPUs away
	if vgc_mark_wide_total(8, 28, 20) != 20 {
		return 3
	}
	// a busy box, or under the line: the configured count
	if vgc_mark_wide_total(8, 28, 0) != 8 {
		return 4
	}
	// a stop of four mutators keeps eight
	if vgc_mark_wide_total(8, 4, 28) != 8 {
		return 5
	}
	// never past vgc_max_markers
	if vgc_mark_wide_total(8, 100, 128) != vgc_max_markers {
		return 6
	}
	// the per-worker sums hold every marker
	if vgc_walk_sum_len < vgc_max_markers * 16 {
		return 7
	}
	return 0
}

// vgc_mark_held_selftest — cx-home/v#62. A stop that holds many mutators
// engages the mark pool on both sides of the pool's line (1 ms of the previous
// mark's work), a quarter of the held mutators and at least four, at most the
// free CPUs; a small heap (its work times the held mutators under the line), a
// busy box and a one-mutator program plan as before. template-render on 20
// mutators ran two cycles in three of its 1.3 ms marks on one marker while the
// 20 waited. A marked set under the several-thread floor plans as the head did
// (a server's small marks). Driven by bench/parallel-alloc/vgc_mark_held_test.v. 0 = ok;
// n = the failed case.
pub fn vgc_mark_held_selftest() u32 {
	ms := u64(1000) * 1000
	us := u64(1000)
	// a marked set over the several-thread floor (the batch rows' 5-14 MB)
	big := vgc_headroom_floor_lo * 2
	// 20 held, a 1.3 ms mark (over the line), 28 free CPUs: five markers, not one
	if vgc_mark_plan_count(8, 1300 * us, ms, 20, 28, true, 0, big, true) != 5 {
		return 1
	}
	// 20 held, a 0.5 ms mark (under the line): the same five
	if vgc_mark_plan_count(8, 500 * us, ms, 20, 28, true, 0, big, true) != 5 {
		return 2
	}
	// 16 held: four; 28 held: seven
	if vgc_mark_plan_count(8, 1300 * us, ms, 16, 28, true, 0, big, true) != 4
		|| vgc_mark_plan_count(8, 1300 * us, ms, 28, 28, true, 0, big, true) != 7 {
		return 3
	}
	// a small heap: 30 us of work times 20 held is under the line, the stop
	// does not weigh (free 0) and the mark stays on one marker
	if vgc_stop_weighs(30 * us, ms, 20) || vgc_mark_plan_count(8, 30 * us, ms, 20, 0, true, 0, big, true) != 1 {
		return 4
	}
	// the stop weighs once the work times the held mutators reaches the line
	if !vgc_stop_weighs(50 * us, ms, 20) || vgc_stop_weighs(5 * ms, ms, 1) {
		return 5
	}
	// one mutator (free 0): one marker per ms of work, as before
	if vgc_mark_plan_count(8, 3 * ms, ms, 1, 0, true, 0, big, true) != 3
		|| vgc_mark_plan_count(8, 1300 * us, ms, 1, 0, true, 0, big, true) != 1 {
		return 6
	}
	// a busy box (free 0) with 20 held: one marker for a 1.3 ms mark, as before
	if vgc_mark_plan_count(8, 1300 * us, ms, 20, 0, true, 0, big, true) != 1 {
		return 7
	}
	// the free CPUs bound the floor: three free, three markers
	if vgc_mark_plan_count(8, 1300 * us, ms, 20, 3, true, 0, big, true) != 3 {
		return 8
	}
	// a long mark keeps one marker per ms: 10 ms on 20 held, ten markers
	if vgc_mark_plan_count(8, 10 * ms, ms, 20, 28, true, 0, big, true) != 10 {
		return 9
	}
	// the back-off's target still caps the plan
	if vgc_mark_plan_count(8, 1300 * us, ms, 20, 28, true, 2, big, true) != 2 {
		return 10
	}
	// VGC_MARK_PAR_MIN_US=0 (line 0): the configured count, widened by the held
	if vgc_mark_plan_count(8, 0, 0, 20, 28, true, 0, big, true) != 21
		|| vgc_mark_plan_count(8, 0, 0, 20, 28, false, 0, big, true) != 8 {
		return 11
	}
	// a configured single marker stays single
	if vgc_mark_plan_count(1, 10 * ms, ms, 20, 28, true, 0, big, true) != 1 {
		return 12
	}
	// cx-home/v#62: a marked set under the several-thread floor (a server's sub-MB mark)
	// plans as the head did: under the line four markers at most (cx-home/v#56's
	// floor), over it one per ms — not a quarter of the held mutators. hello-http
	// k=28 held ~29 threads over ~60 us marks, so the quarter fielded seven markers
	// where four did, and every stop grew and woke them (misc-epic-62/-65/-66)
	small := vgc_headroom_floor_lo / 5
	if vgc_mark_plan_count(8, 60 * us, ms, 29, 28, true, 0, small, true) != 4
		|| vgc_mark_plan_count(8, 1300 * us, ms, 20, 28, true, 0, small, true) != 1
		|| vgc_mark_plan_count(8, 60 * us, ms, 29, 3, true, 0, small, true) != 3
		|| vgc_mark_plan_count(8, 60 * us, ms, 29, 0, true, 0, small, true) != 1 {
		return 13
	}
	// at the floor the quarter holds: 28 held, a 60 us mark, seven
	if vgc_mark_plan_count(8, 60 * us, ms, 28, 28, true, 0, vgc_headroom_floor_lo, true) != 7 {
		return 14
	}
	// a cycle paced as one thread plans as the head did over the floor too: a server
	// whose 3-4 MB marked set crosses 4 MB (87 held at http-json-echo k=28) gets four
	// markers under the line and one per ms over it, not 21 (misc-epic-70)
	if vgc_mark_plan_count(8, 60 * us, ms, 87, 28, true, 0, big, false) != 4
		|| vgc_mark_plan_count(8, 1300 * us, ms, 87, 28, true, 0, big, false) != 1
		|| vgc_mark_plan_count(8, 1300 * us, ms, 87, 28, true, 0, big, true) != 21 {
		return 15
	}
	return 0
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

// vgc_arena_count answers the arenas mapped so far (arenas are never released,
// so it is the high-water mark the VGC_GCTRACE arenas= field reads).
// bench/parallel-alloc/vgc_arena_owner_idle_test.v.
pub fn vgc_arena_count() int {
	return vgc_heap.narenas
}

// vgc_pace_one_thread_selftest — cx-home/v#62. A cycle paces as one allocating thread (the
// quarter) only while at most one thread is stamped as allocating (~1 MB this cycle); then the
// count of threads that allocated 64 KB or more since the last stop decides: several when it
// reaches half the live mutators (and two or more), one when it does not, and it changes the
// answer only when this stop's count and the stop before's agree — one reading on the other side
// keeps the previous cycle's answer. The first collection (start-up) paces as one thread.
// template-render on 20 mutators read 0-1 stamped threads every cycle (the quarter's ~1.4 MB
// budget split 20 ways) and paced ~1,500 of 1,852 cycles at the quarter. json-codec at k=1 read
// its driver and its one worker both over 64 KB in ONE cycle (the hand-over of the work): that
// cycle's GOGC=100 goal of 5 MB raised the run's peak from 12.3 to 15.2 MB (misc-epic-56/-57).
// Under 20 mutators a back-to-back stop reads few threads over 64 KB: template-render's cycle 73
// dropped from a 256 MB headroom to the quarter's 1.4 MB (misc-epic-56's trace).
// Driven by bench/parallel-alloc/vgc_pace_one_thread_test.v. 0 = ok; n = the failed case.
// Arguments: nt, acct, prev (the stop before's acct), live (the live mutators), was_one (the
// previous cycle's answer), cycle.
pub fn vgc_pace_one_thread_selftest() u32 {
	// 20 of 22 mutators over 64 KB two stops running, none stamped: several, whatever came before
	if vgc_pace_one_thread(0, 20, 20, 22, true, 500) || vgc_pace_one_thread(1, 20, 20, 22, false, 500) {
		return 1
	}
	// two of three over 64 KB two stops running: several
	if vgc_pace_one_thread(1, 2, 2, 3, true, 500) {
		return 2
	}
	// one thread by both counts two stops running, or idle: one, whatever came before
	if !vgc_pace_one_thread(1, 1, 1, 3, false, 500) || !vgc_pace_one_thread(0, 0, 0, 3, false, 500)
		|| !vgc_pace_one_thread(0, 1, 0, 3, false, 500) || !vgc_pace_one_thread(0, 1, 1, 2, false, 500) {
		return 3
	}
	// several stamped (two or more, half the live mutators or more): several, whatever the 64 KB counts
	if vgc_pace_one_thread(4, 4, 4, 6, true, 500) || vgc_pace_one_thread(2, 0, 0, 3, true, 500) {
		return 4
	}
	// the first collection is start-up: one, whatever the 64 KB counts
	if !vgc_pace_one_thread(1, 3, 3, 5, false, 0) {
		return 5
	}
	// one stop with two over 64 KB after a one-thread cycle (k=1's hand-over): still one
	if !vgc_pace_one_thread(1, 2, 1, 3, true, 500) || !vgc_pace_one_thread(0, 20, 0, 22, true, 500) {
		return 6
	}
	// one stop with few over 64 KB after several (a back-to-back stop under 20 mutators): still several
	if vgc_pace_one_thread(0, 0, 20, 22, false, 500) || vgc_pace_one_thread(1, 1, 20, 22, false, 500) {
		return 7
	}
	return 0
}

// vgc_pace_answer_selftest (cx-home/v#62, cx-private#1869): the 64 KB count paces as several when
// two or more threads crossed 64 KB at this stop and at the stop before, whatever the live count;
// the ~1 MB stamp at two or more, as the head reads it. A server holds every thread it runs (27
// at http-json-echo C=128 on dev2, 87 at k=28 C=256) and its reactors cross 64 KB between stops
// (VGC_GCTRACE=2 pace lines at C=128: acct 4-12 of 27). Held to half the live mutators, the count
// read that server as one thread at every cycle, and the quarter (goal = marked + 25 %, ~2 MB on
// a 1-2 MB live set) drove ~330 collections a second of ~0.6-2 ms stops: p99 at 128 connections
// 2.34-2.54 ms against Python's 1.60 (misc-epic-91/-92/-95). VGC_ONE_THREAD_PCT=100 on the same
// build cut the collections ~4x and doubled the requests a second on the same box. One reading
// on the other side still keeps the previous cycle's answer, and one thread over 64 KB is one.
// 0 = pass, else the failing check. Driven by bench/parallel-alloc/vgc_pace_answer_test.v.
pub fn vgc_pace_answer_selftest() u32 {
	// server readings, two stops running, after a cycle that answered one: several
	if vgc_pace_one_thread(0, 7, 7, 87, true, 500) || vgc_pace_one_thread(1, 3, 3, 39, true, 500)
		|| vgc_pace_one_thread(0, 2, 2, 15, true, 500) || vgc_pace_one_thread(1, 2, 2, 6, true, 500)
		|| vgc_pace_one_thread(0, 12, 5, 27, true, 500) {
		return 1
	}
	// one burst on a server pacing as one, at this stop or the stop before only: still one
	if !vgc_pace_one_thread(0, 7, 1, 87, true, 500) || !vgc_pace_one_thread(0, 1, 7, 87, true, 500)
		|| !vgc_pace_one_thread(0, 12, 0, 27, true, 500) {
		return 2
	}
	// batch workers k of k+2, two stops running: several, at k = 1 (two of three), 16, 20, 28
	if vgc_pace_one_thread(0, 2, 2, 3, true, 500) || vgc_pace_one_thread(0, 16, 16, 18, true, 500)
		|| vgc_pace_one_thread(1, 20, 20, 22, true, 500) || vgc_pace_one_thread(0, 28, 28, 30, true, 500) {
		return 3
	}
	// two at both stops is several whatever the live count; one at both stops is one
	if vgc_pace_one_thread(0, 2, 2, 5, true, 500) || !vgc_pace_one_thread(0, 1, 1, 5, false, 500) {
		return 4
	}
	// the ~1 MB stamp at two or more is several whatever the live count and the cycle before,
	// as the head reads it: a server's pacing is the head's (http-json-echo k=4 C=256, P6's
	// VGC_GCTRACE=2 trace: 61 of 404 cycles several, every one by the stamp, none by the 64 KB
	// count). The half-of-live stamp (a2c8c5f15, 88fdac947) held http-json-echo k=12 C=256 at
	// the one-thread quarter, 6,347 collections against the head's 1,966, 80k requests/s
	// against 101-113k (misc-epic-71, the d1 trace)
	if vgc_pace_one_thread(4, 7, 6, 87, false, 500) || vgc_pace_one_thread(3, 3, 0, 87, false, 500)
		|| vgc_pace_one_thread(2, 0, 0, 4, false, 500) || vgc_pace_one_thread(2, 2, 2, 87, false, 500) {
		return 5
	}
	// after a one-thread cycle the stamp enters several at two or more (the head's reading:
	// two threads over ~1 MB under a one-thread goal), so hello-http k=4 is not held at one
	if vgc_pace_one_thread(3, 3, 0, 87, true, 500) || vgc_pace_one_thread(2, 2, 2, 15, true, 500) {
		return 6
	}
	return 0
}

// vgc_pace_startup_prev_selftest (cx-home/v#56, csv-aggregate's peak): the first collection is the
// program's start-up (vgc_pace_one_thread answers one there, whatever its counts), so its 64 KB
// count is no 'stop before' for the second collection to agree with. csv-aggregate 100 MB (cx
// interpreted) read 2 of 2 live threads over 64 KB at the start-up stop and 2 of 3 at the next:
// the two stops 'agreed', gc 1 paced as several (goal 4 MB, headroom 4,096 KB against the
// one-thread 256 KB floor) and the run ended at 2 collections with peak RSS 15.8 MB vs Python
// 3.12's 14.1 (VGC_GCTRACE=2 pace lines). Two readings after start-up still make several (a batch
// of k workers), and the ~1 MB stamp at two or more still does at any cycle past start-up.
// 0 = pass, else the failed check. Driven by bench/parallel-alloc/vgc_pace_startup_prev_test.v.
pub fn vgc_pace_startup_prev_selftest() u32 {
	// the stop after start-up, 2 of 3 over 64 KB now and 2 of 2 at start-up: one
	if !vgc_pace_one_thread(0, 2, 2, 3, true, 1) || !vgc_pace_one_thread(1, 2, 2, 2, true, 1) {
		return 1
	}
	// two readings past start-up (cycles 1 and 2) agree: several, as a batch reads
	if vgc_pace_one_thread(0, 2, 2, 3, true, 2) || vgc_pace_one_thread(0, 16, 16, 18, true, 2) {
		return 2
	}
	// the stamp at two or more past start-up: several at the stop after start-up too
	if vgc_pace_one_thread(2, 2, 2, 3, true, 1) {
		return 3
	}
	// the stop after start-up keeps the one-thread answer start-up gave when only it reads several
	if !vgc_pace_one_thread(0, 2, 0, 3, true, 1) {
		return 4
	}
	return 0
}

// vgc_minor_flag_selftest (cx-home/v#56 step 2): a cycle's kind belongs to the thread whose phase
// CAS started it. Every mutator over the trigger calls vgc_gc_start — beside a concurrent cycle's
// middle that is every allocating thread on every amortized check (heap_live stays over next_gc
// until the cycle ends) — and a call that loses the CAS must not touch the running cycle's
// vgc_minor_this_cycle. Built here: a full cycle in flight (phase mark, the flag false, as
// vgc_gc_start_concurrent leaves it after its CAS) and the young regime armed so that a plan
// made now answers minor; a losing call reads its plan and returns. 0 = pass, else the failed
// check. Driven by bench/parallel-alloc/vgc_minor_flag_test.v.
pub fn vgc_minor_flag_selftest() u32 {
	$if vgc_concurrent ? {
		s_phase := C.vgc_atomic_load_u32(&vgc_heap.gc_phase)
		s_flag := vgc_minor_this_cycle
		s_young := vgc_young_on
		s_minors := vgc_young_minors
		s_count := vgc_minor_count
		s_fm := vgc_full_marked
		s_fg := vgc_full_goal
		s_ff := C.vgc_atomic_load_u32(&vgc_force_full)
		s_pm := vgc_perm_mode
		s_pr := vgc_perm_request
		mut rc := u32(0)
		if s_phase != vgc_phase_off {
			return 9
		}
		// the full cycle in flight: its CAS is taken and it is not minor
		C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_mark)
		vgc_minor_this_cycle = false
		// the young regime armed after a full: a plan made now answers minor
		vgc_young_on = 1
		vgc_young_minors = 8
		vgc_minor_count = 0
		vgc_full_marked = 0
		vgc_full_goal = 0
		C.vgc_atomic_store_u32(&vgc_force_full, 0)
		vgc_perm_mode = 0
		vgc_perm_request = false
		if !vgc_minor_plan(false) {
			rc = 1
		} else {
			// a mutator over the trigger beside the cycle: its CAS fails
			vgc_gc_start()
			if C.vgc_atomic_load_u32(&vgc_heap.gc_phase) != vgc_phase_mark {
				rc = 2
			} else if vgc_minor_this_cycle {
				rc = 3
			}
		}
		vgc_perm_request = s_pr
		vgc_perm_mode = s_pm
		C.vgc_atomic_store_u32(&vgc_force_full, s_ff)
		vgc_full_goal = s_fg
		vgc_full_marked = s_fm
		vgc_minor_count = s_count
		vgc_young_minors = s_minors
		vgc_young_on = s_young
		vgc_minor_this_cycle = s_flag
		C.vgc_atomic_store_u32(&vgc_heap.gc_phase, s_phase)
		return rc
	} $else {
		return 0
	}
}

// vgc_stack_scan_selftest (cx-home/v#56 lever 16): the thread-stack scan reads every byte offset a
// with a + 8 <= hi (cx-home/v#60) and shades each value in [vgc_arena_lo, vgc_arena_hi). Its byte loop
// moves into vgc_stack_candidates (vgc_platform.h), which hands back up to cap candidate offsets a call
// and where to go on: driven to the end of a range, it must answer exactly the offsets the byte loop
// would, in address order, for every start and end offset (aligned or not) and every cap — the bounds
// themselves (alo in, ahi out), a value whose last byte would lie past hi, and a run of random bytes.
// 0 = pass, else the failed check. Driven by bench/parallel-alloc/vgc_stack_scan_test.v.
fn vgc_sst_put(at usize, v usize) {
	unsafe { C.memcpy(voidptr(at), &v, sizeof(usize)) }
}

// the offsets vgc_stack_candidates answers over [lo, hi), cap at a time: their count and an ordered hash
fn vgc_sst_scan(lo usize, hi usize, alo usize, ahi usize, cap int) (int, u64) {
	mut hits := [64]usize{}
	mut n := 0
	mut h := u64(0)
	mut addr := lo
	for addr + sizeof(usize) <= hi {
		mut next := hi
		k := C.vgc_stack_candidates(addr, hi, alo, ahi, &hits[0], cap, &next)
		if k < 0 || k > cap || (k == 0 && next <= addr) {
			return -1, h
		}
		for i in 0 .. k {
			n++
			h = h * 1000003 + u64(hits[i] - lo) + 1
		}
		addr = next
	}
	return n, h
}

// the byte loop vgc_scan_stack_range ran before lever 16, as the reference
fn vgc_sst_ref(lo usize, hi usize, alo usize, ahi usize) (int, u64) {
	mut n := 0
	mut h := u64(0)
	mut addr := lo
	for addr + sizeof(usize) <= hi {
		mut val := usize(0)
		unsafe { C.memcpy(&val, voidptr(addr), sizeof(usize)) }
		if val >= alo && val < ahi {
			n++
			h = h * 1000003 + u64(addr - lo) + 1
		}
		addr++
	}
	return n, h
}

pub fn vgc_stack_scan_selftest() u32 {
	alo := usize(0x2000_0000)
	ahi := usize(0x6000_0000)
	mut buf := [168]u8{}
	base := unsafe { usize(voidptr(&buf[0])) }
	// a run of random bytes, then the planted values over it
	mut x := u64(0x9e3779b97f4a7c15)
	for i in 0 .. 168 {
		x = x * 6364136223846793005 + 1442695040888963407
		buf[i] = u8(x >> 56)
	}
	vgc_sst_put(base + 0, alo) // the low bound: in
	vgc_sst_put(base + 13, ahi - 1) // the last address: in
	vgc_sst_put(base + 30, ahi) // the high bound: out
	vgc_sst_put(base + 41, alo - 1) // under the low bound: out
	vgc_sst_put(base + 57, alo + 0x1234)
	vgc_sst_put(base + 77, alo + 0x77)
	vgc_sst_put(base + 99, ahi - 0x99)
	vgc_sst_put(base + 120, alo + 0x120)
	vgc_sst_put(base + 160, alo + 8) // the last offset of the whole range
	// check 1: the whole range, as the byte loop reads it
	rn, rh := vgc_sst_ref(base, base + 168, alo, ahi)
	cn, ch := vgc_sst_scan(base, base + 168, alo, ahi, 64)
	if rn < 7 || cn != rn || ch != rh {
		return 1
	}
	// check 2: every start and end offset, aligned or not, and a cap of 1, 3 and 64
	for lo_off in 0 .. 17 {
		for hi_off in lo_off .. 169 {
			lo := base + usize(lo_off)
			hi := base + usize(hi_off)
			n0, h0 := vgc_sst_ref(lo, hi, alo, ahi)
			for cap in [1, 3, 64]! {
				n1, h1 := vgc_sst_scan(lo, hi, alo, ahi, cap)
				if n1 != n0 || h1 != h0 {
					return 2
				}
			}
		}
	}
	// check 3: the bounds one word at a time — alo and ahi - 1 in, ahi and alo - 1 out, and a value
	// whose last byte lies past hi is not read
	mut hits := [64]usize{}
	mut next := usize(0)
	if C.vgc_stack_candidates(base + 0, base + 8, alo, ahi, &hits[0], 64, &next) != 1 || hits[0] != base {
		return 3
	}
	if C.vgc_stack_candidates(base + 13, base + 21, alo, ahi, &hits[0], 64, &next) != 1
		|| hits[0] != base + 13 {
		return 3
	}
	if C.vgc_stack_candidates(base + 30, base + 38, alo, ahi, &hits[0], 64, &next) != 0
		|| C.vgc_stack_candidates(base + 41, base + 49, alo, ahi, &hits[0], 64, &next) != 0 {
		return 3
	}
	if C.vgc_stack_candidates(base + 160, base + 167, alo, ahi, &hits[0], 64, &next) != 0
		|| next != base + 167 {
		return 3
	}
	return 0
}

// vgc_arena_of_selftest (cx-platform-store#55): vgc_arena_of — the arena lookup of the pool's span
// split, tail split, coalesce and decommit checks — answers every address of every arena from the
// address maps, never from a scan of the arena table. An arena is a 64 MB mmap at whatever address
// the OS hands out, so it straddles two 64 MB chunks of vgc_addr_map and shares each with a
// neighbour; for the part of an arena in a chunk whose first entry names the neighbour the answer is
// vgc_addr_map2 (cx-home/v#15 lever 3, which vgc_find_arena reads). Probes: each arena's first and
// last byte and both sides of every chunk boundary inside it. Returns (0 = pass else the failed
// check, the probes whose chunk's first entry names another arena, the scans during the probes).
// Driven by bench/parallel-alloc/vgc_arena_of_test.v.
pub fn vgc_arena_of_selftest() (u32, int, u64) {
	nar := int(C.vgc_atomic_load_u32(&u32(voidptr(&vgc_heap.narenas))))
	if nar < 2 {
		return 1, 0, 0
	}
	mut probes := [64]usize{}
	mut nshared := 0
	before := C.vgc_atomic_load_u64(&vgc_arena_of_scans)
	for i in 0 .. nar {
		base := vgc_heap.arenas[i].base
		size := vgc_heap.arenas[i].size
		if size == 0 {
			continue
		}
		mut n := 0
		probes[n] = base
		n++
		probes[n] = base + size - 1
		n++
		chunk := usize(1) << 26
		mut b := (base / chunk + 1) * chunk
		for b < base + size && n + 2 <= 64 {
			probes[n] = b - 1
			n++
			probes[n] = b
			n++
			b += chunk
		}
		for k in 0 .. n {
			p := probes[k]
			if vgc_arena_of(p) != i {
				return 2, nshared, C.vgc_atomic_load_u64(&vgc_arena_of_scans) - before
			}
			if C.vgc_addr_to_arena(p) != i {
				nshared++
			}
		}
	}
	return 0, nshared, C.vgc_atomic_load_u64(&vgc_arena_of_scans) - before
}

// vgc_pool_kind_selftest (cx-platform-store#55): the pool answers "a span of this kind of n pages" without
// walking the spans of another kind. cx-home/v#58's arena kinds (plain, frames, small) share the pooled size
// lists, and vgc_pool_at walked a whole list (vgc_pool_first_of_kind, one arena lookup a span) to learn it held
// none of the asked kind — vgc_pool_best_fit and vgc_pool_kept_tail then asked every populated size above the
// request, so one refill walked every pooled span of the other kinds (the store daemon at 1,000,000 documents:
// most of the lock-holding thread's samples once vgc_arena_of's scan was gone). n plain spans (descriptors
// outside the arenas read as plain) on the list of np pages, nothing else there: asking it for a small span must
// look at no span; asking it for a plain one, at one. Answers (0 = pass else the failed check, the steps of the
// small ask, the steps of the plain ask). Driven by bench/parallel-alloc/vgc_pool_kind_test.v.
pub fn vgc_pool_kind_selftest(n int) (u32, u64, u64) {
	np := u32(8190)
	descs := unsafe { &VGC_Span(C.calloc(usize(n), sizeof(VGC_Span))) }
	if descs == unsafe { nil } {
		return 1, 0, 0
	}
	C.vgc_mutex_lock(&vgc_heap.free_spans_lock)
	saved_head := vgc_heap.free_spans[np]
	saved_tail := vgc_heap.free_spans_tail[np]
	saved_cold := vgc_heap.free_spans_cold[np]
	saved_bytes := vgc_heap.pool_bytes
	saved_hot_w := vgc_pool_hot_bits[np >> 6]
	saved_cold_w := vgc_pool_cold_bits[np >> 6]
	saved_k := vgc_pool_kind_save(np)
	vgc_heap.free_spans[np] = unsafe { nil }
	vgc_heap.free_spans_tail[np] = unsafe { nil }
	vgc_heap.free_spans_cold[np] = unsafe { nil }
	vgc_pool_kind_clear(np)
	for i in 0 .. n {
		mut d := unsafe { &descs[i] }
		d.npages = np
		vgc_pool_push(mut d)
	}
	mut rc := u32(0)
	vgc_pool_kind_steps = 0
	small := vgc_pool_at(np, vgc_kind_small)
	small_steps := vgc_pool_kind_steps
	vgc_pool_kind_steps = 0
	plain := vgc_pool_at(np, vgc_kind_plain)
	plain_steps := vgc_pool_kind_steps
	if small != unsafe { nil } {
		rc = 2
	} else if plain == unsafe { nil } {
		rc = 3
	}
	for i in 0 .. n {
		mut d := unsafe { &descs[i] }
		vgc_pool_unlink(mut d)
	}
	vgc_heap.free_spans[np] = saved_head
	vgc_heap.free_spans_tail[np] = saved_tail
	vgc_heap.free_spans_cold[np] = saved_cold
	vgc_heap.pool_bytes = saved_bytes
	vgc_pool_hot_bits[np >> 6] = saved_hot_w
	vgc_pool_cold_bits[np >> 6] = saved_cold_w
	vgc_pool_kind_restore(np, saved_k)
	C.vgc_mutex_unlock(&vgc_heap.free_spans_lock)
	unsafe { C.free(descs) }
	return rc, small_steps, plain_steps
}

// the pool's per-kind tallies of list np (vgc_pool_kind_tally), saved, cleared and restored by a selftest
// that files its own descriptors on the list
fn vgc_pool_kind_save(np u32) [6]u32 {
	mut k := [6]u32{}
	for r in 0 .. 6 {
		k[r] = vgc_pool_kind_tally[r * 8193 + int(np)]
	}
	return k
}

fn vgc_pool_kind_clear(np u32) {
	vgc_pool_kind_restore(np, [6]u32{})
}

fn vgc_pool_kind_restore(np u32, k [6]u32) {
	bit := u64(1) << u64(np & 63)
	for r in 0 .. 6 {
		vgc_pool_kind_tally[r * 8193 + int(np)] = k[r]
		if k[r] > 0 {
			vgc_pool_kind_bits[r * 129 + int(np >> 6)] |= bit
		} else {
			vgc_pool_kind_bits[r * 129 + int(np >> 6)] &= ~bit
		}
	}
}

// vgc_find_arena_selftest (cx-platform-store#55): an address in a 64 MB chunk that no arena touches resolves to
// -1 from the address map alone — every chunk an arena touches has a first map entry (vgc_addr_map_register), so
// an empty entry means no arena, and the arena table is not scanned. The mark asks vgc_find_span for every word
// it reads that lies inside [vgc_arena_lo, vgc_arena_hi); on a heap of hundreds of arenas spread over the address
// space most such non-pointers lie between arenas, and each one scanned the whole table (the store daemon at
// 1,000,000 documents: 70 % of a 4 s sample in that loop, a forced collection inside one put-docs). Probes: the
// chunk below the lowest arena, the chunk above the highest, and every chunk inside the hull no arena touches.
// Answers (0 = pass else the failed check, the probes, the scans during the probes).
pub fn vgc_find_arena_selftest() (u32, int, u64) {
	nar := int(C.vgc_atomic_load_u32(&u32(voidptr(&vgc_heap.narenas))))
	if nar < 1 {
		return 1, 0, 0
	}
	chunk := usize(1) << 26
	mut lo := vgc_heap.arenas[0].base
	mut hi := vgc_heap.arenas[0].base + vgc_heap.arenas[0].size
	for i in 1 .. nar {
		if vgc_heap.arenas[i].base < lo {
			lo = vgc_heap.arenas[i].base
		}
		if vgc_heap.arenas[i].base + vgc_heap.arenas[i].size > hi {
			hi = vgc_heap.arenas[i].base + vgc_heap.arenas[i].size
		}
	}
	mut probes := 0
	before := C.vgc_atomic_load_u64(&vgc_find_arena_scans)
	mut c := (lo / chunk - 1) * chunk
	end := (hi / chunk + 2) * chunk
	for c < end && probes < 4096 {
		if C.vgc_addr_to_arena(c) < 0 && C.vgc_addr_to_arena(c + chunk - 1) < 0 {
			probes++
			if vgc_find_arena(c + 4096) != -1 {
				return 2, probes, C.vgc_atomic_load_u64(&vgc_find_arena_scans) - before
			}
		}
		c += chunk
	}
	return 0, probes, C.vgc_atomic_load_u64(&vgc_find_arena_scans) - before
}
