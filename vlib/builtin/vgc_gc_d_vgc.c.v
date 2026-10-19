// vgc_gc_d_vgc.c.v - V Garbage Collector: Mark, sweep, and orchestration
// Translated from Go's runtime GC (mgc.go, mgcmark.go, mgcsweep.go, mgcwork.go, mgcpacer.go)
// Concurrent tri-color mark-and-sweep with parallel marking.

@[has_globals]
module builtin

// ============================================================
// GC Orchestration (translated from Go's runtime.gcStart, gcMarkDone, gcMarkTermination)
// ============================================================

// cx #316: per-cycle safe-region coverage snapshot. Written ONLY by the
// collector (exclusive under cache_lock across the whole cycle): reset in the
// park-wait count loop (cooperative) / suspend loops (legacy, concurrent-mark),
// set at the suspend loop's authoritative safe==1 read, consumed by
// vgc_scan_suspended_roots and the vgc_passive coverage probe. A snapshot —
// not a live re-read — so the scan and the probe see EXACTLY the set the
// suspend loop exempted, even if a thread flips safe mid-cycle (it then spins
// in its exit handshake; its recorded roots stay valid — see
// vgc_safe_exit_handshake in vgc_platform.h). cx-home/v#27: the snapshot is
// VGC_Cache.cov_safe, per slot — no array sized to a cap.

// cx #316 observability: mach suspensions actually ACKed across all STW cycles
// (collector-exclusive increments). The safe-region selftest asserts this does
// NOT advance while the only other thread is parked in a safe region — i.e.
// the STW suspend set really is the awake set.
__global vgc_stat_mach_suspends = u64(0)

// cx #973: data-segment root ranges, CACHED at vgc_init (single-threaded,
// load-constructor context) instead of re-derived inside every STW window.
// vgc_data_segments calls the platform loader (_dyld_get_image_header/dladdr
// on darwin, dl_iterate_phdr on linux), which takes the LOADER LOCK — and a
// mach-suspended straggler can be frozen HOLDING that lock (the committed #973
// sample has one frozen in libSystem_atfork_parent mid-fork), deadlocking the
// collector inside vgc_mark_roots. The ranges are static per loaded image
// (main executable + the image carrying vgc), so deriving them once outside
// STW removes every loader-lock acquisition from the collector. 8 slots: 3
// mach-o data segments x 2 images, or the writable ELF PT_LOADs of both.
__global vgc_seg_lo = [8]usize{}
__global vgc_seg_hi = [8]usize{}
__global vgc_nseg = int(0)

// cx #973: derive + cache the data-segment root ranges. Called from vgc_init
// (before any second thread exists). The mark-time fallback in vgc_mark_roots
// exists only for the _vinit-before-vgc_init ordering quirk (spans can be
// allocated before vgc_init runs) and would fire in a still-single-threaded
// world, where the loader lock cannot be held by a frozen peer.
fn vgc_cache_data_segments() {
	vgc_nseg = C.vgc_data_segments(&vgc_seg_lo[0], &vgc_seg_hi[0], 8)
}

// cx-home/v#15: the current cycle's phase stamps (ns), written by the collector
// under STW, read by vgc_gctrace_emit for the VGC_GCTRACE=2 phase line:
// 0 world stopped, 1 mark bits cleared, 2 suspended roots scanned, 3 data
// segments scanned, 4 stacks scanned, 5 mark drained, 6 marked counted,
// 7 swept. The cycle's t0 and end are vgc_gc_t0 / vgc_gc_last_end.
__global vgc_ph = [8]u64{}

@[inline]
fn vgc_ph_us(a u64, b u64) u64 {
	if b > a {
		return (b - a) / 1000
	}
	return 0
}

// vgc_gc_start triggers a garbage collection cycle.
// Translated from Go's gcStart() in mgc.go.
// Flow: sweep termination (STW) -> full STW mark -> sweep -> resume.
// Invoked via the vgc_run_gc_spilled trampoline (vgc_platform.h), which has
// already recorded THIS thread's stack range with callee-saved registers
// spilled — so vgc_gc_start must NOT re-record the collector's own range.
@[export: 'vgc_gc_start']
fn vgc_gc_start() {
	$if vgc_concurrent ? {
		// cx-private#1910: the concurrent-mark cycle (two stops, the mark beside
		// the mutators) when the last mark's work was long enough to be worth
		// its second root scan and the dirty re-scan — the same 1 ms the marker
		// pool engages at — else the stop-the-world cycle below. Measured on
		// the door (27 threads, ~60 MB marked, VGC_HEADROOM_MB=4): STW pause
		// p50 129 ms / p99 443 ms, concurrent 8.9 / 17.6 ms; on the k=8 echo
		// (2 MB marked, a 1.2 ms mark): STW 3.4 ms, concurrent 5-8 ms. VGC_CM=0
		// never, VGC_CM=1 always, VGC_CM_MIN_US the threshold.
		// The concurrent cycle scans the roots a second time at termination, so
		// it pays when the mark is the larger part: the last mark's work at
		// least VGC_CM_MIN_US AND at least twice the last root scan (suspended
		// registers + data segments + stacks). The k=8 echo (mark 1.2 ms, roots
		// 0.9 ms) stays on the STW cycle; the door (mark 20-40 ms, roots 1-2 ms)
		// takes the concurrent one.
		// The feedback (vgc_cm_backoff, vgc_d_vgc.c.v): a concurrent cycle whose
		// stops were no shorter than the last STW pause sends the next cycles
		// here, and the concurrent cycle is probed again after them.
		// cut 1: and only when the middle's births are forecast to fit twice
		// the born bound (vgc_cm_born_fits) — sixteen hot allocators at ~10
		// GB/s put 300 MB through a 30 ms middle, a probe that lost before it
		// ran; the bound's throttle (vgc_cm_throttle) is the guarantee.
		// cx-home/v#15: the promotion cycle is stop-the-world under every VGC_CM
		// (an object born in a concurrent middle is filled after the stop with
		// no barrier, so it must not be promoted)
		promote := vgc_perm_mode != 0
			&& ((vgc_perm_on == 0 && vgc_perm_cycle != 0 && vgc_heap.gc_cycle + 1 >= vgc_perm_cycle) || vgc_perm_request)
		if !promote && (vgc_cm_mode == 1 || (vgc_cm_mode == 2 && vgc_cm_backoff == 0
			&& vgc_mark_last_work_ns >= vgc_cm_min_ns
			&& vgc_mark_last_work_ns >= 2 * vgc_root_last_ns && vgc_cm_born_fits())) {
			vgc_gc_start_concurrent()
			return
		}
	}
	// Only one GC at a time
	mut expected := vgc_phase_off
	if !C.vgc_atomic_cas_u32(&vgc_heap.gc_phase, &expected, vgc_phase_mark) {
		return
	}
	$if vgc_concurrent ? {
		// one backoff cycle spent (after the CAS: every thread that reached the
		// pacer calls in for the same cycle)
		if vgc_cm_backoff > 0 {
			vgc_cm_backoff--
		}
	}
	// cx-home/v#17: the collector's own carves never wait for its collection
	vgc_gc_owner = C.vgc_get_cache_idx()
	$if vgc_concurrent ? {
		vgc_cm_this_cycle = false
	}
	vgc_gc_t0 = C.vgc_now_ns() // cycle-cost measurement for the adaptive pacer (#71)
	vgc_gc_cpu_t0 = C.vgc_thread_cpu_ns() // cx-home/v#42: the cost in CPU time
	vgc_gc_wait_cpu = 0
	// cx-home/v#16: this cycle's marker count, and the pool threads created
	// BEFORE the world stops (see vgc_mark_workers_cfg).
	vgc_mark_nworkers_cur = vgc_mark_plan()
	vgc_walk_nworkers_cur = vgc_walk_plan() // fable-v16: the span walks' count

	// Take free_spans_lock for the WHOLE cycle, BEFORE stopping the world, so no
	// mutator is ever frozen mid-vgc_get_free_span holding it (which, if the lock
	// were then stolen, would resume into a corrupted free list and hand out a span
	// with a garbage base). Acquired while mutators still run, a current holder
	// releases promptly; thereafter the collector owns it and vgc_put_free_span
	// (collector-only) runs lock-free. Released right after sweep, before resume.
	// (Lock order: free_spans_lock then cache_lock; no mutator holds free_spans_lock
	// and then waits on cache_lock, so no deadlock.)
	// The cooperative-safepoint collector (DEFAULT) must NOT hold any allocator lock
	// while waiting for mutators to self-park (a thread blocked on the lock can't reach
	// the poll) — it acquires free_spans_lock + runs sweep_finish AFTER the park wait,
	// below. Only the legacy mach-suspend collector (-d vgc_legacy_stw) takes it up-front.
	$if vgc_legacy_stw ? {
		C.vgc_mutex_lock(&vgc_heap.free_spans_lock)
		// === Phase 1: Sweep Termination (STW) ===
		// Ensure any previous sweep is complete
		vgc_sweep_finish()
	}

	// === Stop the world via OS-level mach suspend ===
	// Suspend every live registered mutator (except this collector). Unlike the
	// cooperative alloc-path safepoint (which cannot stop a thread blocked in a
	// syscall or spinning in a tight non-allocating loop), mach thread_suspend
	// stops a thread in ANY state. Mechanism validated standalone in
	// bench/parallel-alloc/suspend_world.c.
	self_idx := C.vgc_get_cache_idx()
	if vgc_watch_addr != 0 {
		vgc_watch_cycles++ // DIAGNOSTIC: count collections observed since the watch was set
		// Per-cycle reset of the root-scan localizers so each cycle's verdict
		// reflects THIS cycle's root scan (not a stale prior cycle's).
		vgc_watch_in_stack = 0
		vgc_watch_in_reg = 0
		vgc_watch_in_spawn = 0
		vgc_watch_rng_cov = 0
		vgc_watch_marked = 0
	}
	C.vgc_trace(5, self_idx, u64(vgc_heap.gc_cycle), u64(vgc_heap.ncaches)) // GC_BEG
	// VGC_Cache.cov_susp records which slots THIS cycle suspended, so resume targets
	// exactly them. Default path: every other registered mutator. Cooperative path:
	// only the stragglers that did not self-park. Used by both branches + the
	// resume loop. cx-home/v#28: every suspend is two passes — request for all,
	// then settle (ack) for all — so N parked stragglers cost one scheduling
	// latency per cycle, not N.
	vgc_stw_stop(self_idx)

	// Clear mark bits on all spans (prepare for new cycle)
	vgc_ph[0] = C.vgc_now_ns()
	vgc_clear_mark_bits()
	vgc_ph[1] = C.vgc_now_ns()
	vgc_watch_snapshot(0) // STAGE 0: post-clear (expect found+in_use+alloc, mark=0)

	// Scan each suspended thread's roots: refresh its stack range from the
	// actual suspended SP and shade its register-resident roots (the exact roots
	// a stack-only scan misses; validated in bench/parallel-alloc/stw_root_scan.c).
	vgc_scan_suspended_roots(self_idx)
	vgc_ph[2] = C.vgc_now_ns()
	vgc_watch_snapshot(1) // STAGE 1: post suspended-thread reg/stack roots (main's reg holds c)
	$if vgc_rangedump ? {
		// #58 diagnostic: dump EVERY registered thread's post-refresh scan range so a
		// rootfind EXTERNAL holder can be correlated — is it below stack_lo (size under-
		// estimated), above stack_hi (base wrong), or in no range at all (unregistered peer)?
		for di in 0 .. vgc_heap.ncaches {
			dc := unsafe { vgc_cache(di) }
			if dc.registered && dc.mach_port != 0 {
				C.write(2, c'[rangedump] ', usize(12))
				C.vgc_say(0x5a9e, u64(di))
				C.vgc_say(0x5a10, u64(dc.stack_lo))
				C.vgc_say(0x5a11, u64(dc.stack_hi))
				C.vgc_say(0x5aba, u64(dc.stack_base))
			}
		}
	}

	$if vgc_spcheck ? {
		// #58: shadow the exact ranges this cycle's root scan will use. Stragglers'
		// ranges were just refreshed from their captured SP (vgc_scan_suspended_roots);
		// parkers self-recorded theirs in vgc_park_spill. World is stopped: consistent.
		for si in 0 .. vgc_heap.ncaches {
			sc := unsafe { vgc_cache(si) }
			if sc.registered && si < 64 {
				vgc_spchk_lo[si] = sc.stack_lo
				vgc_spchk_hi[si] = sc.stack_hi
				vgc_spchk_cyc[si] = u64(vgc_heap.gc_cycle)
				vgc_spchk_parked[si] = u64(C.vgc_atomic_load_u32(&vgc_cache(si).stopped))
			}
		}
	}

	// === Phase 2: Mark (parallel) ===
	// Enable write barrier (for concurrent correctness)
	vgc_wb_set(1)

	// NOTE: the collector's own stack range was already recorded (with
	// registers spilled) by the vgc_run_gc_spilled trampoline before this
	// function was entered. Do NOT call vgc_refresh_stack_range() here — that
	// would overwrite the range with a higher SP and drop the spilled regs.

	// Scan roots: stacks + globals (conservative scanning)
	vgc_mark_roots()
	vgc_root_last_ns = vgc_ph[4] - vgc_ph[1] // cx-private#1910: the next cycle's selection
	vgc_watch_snapshot(2) // STAGE 2: post stack roots

	// Shade in-flight spawn-argument structs. These are live (a freshly created
	// thread is about to read them) but unreachable from any scanned stack during
	// the create->start handoff, because the child is not yet registered. Reading
	// the array without the lock is safe here: the world is stopped, so no mutator
	// can be mid add/remove except one frozen holding the lock, and an entry is
	// only counted after its slot is written. (See vgc_spawn_roots.)
	for i in 0 .. vgc_nspawn_roots {
		root := usize(unsafe { vgc_spawn_roots[i] })
		vgc_shade_spawn_root(root)
		// DIAGNOSTIC (root-scan-miss localizer): is the watched object the spawn
		// arg itself (bit0), or reachable from it via arg->...->c (bit1)? Pins
		// whether the spawn-root drain actually reaches c.
		if vgc_watch_addr != 0 && root != 0 {
			if root == vgc_watch_addr {
				vgc_watch_in_spawn |= 1
			} else {
				vgc_watch_scan_obj(root)
			}
		}
	}
	vgc_watch_snapshot(3) // STAGE 3: post spawn-root shade
	$if vgc_concurrent ? {
		// cx-home/v#15: the permanent spans written since the last cycle (their
		// objects are black from the clear; what they point to is found here)
		if vgc_perm_on != 0 {
			t_rescan := C.vgc_now_ns()
			vgc_rescan_dirty_spans(false)
			vgc_perm_rescan_ns = C.vgc_now_ns() - t_rescan
		}
	}

	// FULL stop-the-world mark+sweep: the world stays stopped from here through
	// the end of sweep. The previous design resumed mutators here and marked
	// concurrently, but objects allocated DURING the concurrent mark were not
	// alloc-blacked and stack-local pointer writes carry no write barrier, so a
	// freshly-allocated-but-live object (e.g. `last` in a tight alloc loop) was
	// swept -> use-after-free. Keeping the world stopped through sweep removes
	// that entire unsound-concurrency window. (Concurrency is a later perf
	// optimization that must come with alloc-black + a correct barrier.)

	// Parallel mark: drain the work queue (workers only; mutators are stopped)
	mcpu0, mwait0 := vgc_mark_cpu_begin()
	vgc_parallel_mark()
	vgc_watch_snapshot(4) // STAGE 4: post parallel-mark drain

	// === Phase 3: Mark Termination (brief STW) ===
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_mark_term)

	// Final drain of work queue
	vgc_drain_mark_work(0)
	vgc_ph[5] = C.vgc_now_ns()
	vgc_mark_last_ns = vgc_ph[5] - vgc_ph[4] // the next cycle's parallel-mark decision (cx-home/v#16)
	// The single-marker-equivalent work of that mark: n markers took last_ns,
	// so one would have taken about n x last_ns. The next cycle plans its
	// marker count from the WORK, not the wall time a parallel cycle left —
	// planned from the wall time, eight markers that cut a 3 ms mark to 0.6 ms
	// dropped the next cycle back to one marker, which took 3 ms again: the
	// count flapped 1/8 every other cycle and the pool's CPU was spent on
	// marks that one or two markers cover (json-codec 1 MB: user +15 % for
	// wall -5 %).
	vgc_mark_last_work_ns = vgc_mark_last_ns * u64(if vgc_mark_nworkers_cur > 1 {
		vgc_mark_nworkers_cur
	} else {
		1
	})
	vgc_mark_work_from_cpu(mcpu0, mwait0)
	vgc_watch_snapshot(5) // STAGE 5: post final drain (mark term)
	$if vgc_concurrent ? {
		// cx-home/v#15: the promotion cycle, and the verifier's full re-mark
		if vgc_perm_mode != 0
			&& ((vgc_perm_on == 0 && vgc_perm_cycle != 0 && vgc_heap.gc_cycle + 1 >= vgc_perm_cycle) || vgc_perm_request) {
			vgc_perm_promote()
		}
		if vgc_perm_on != 0 {
			vgc_cm_verify(self_idx)
		}
	}

	// Disable write barrier (cx-home/v#15: the permanent regime stays)
	vgc_wb_set(vgc_perm_on * 2)

	// Compute live bytes from mark bits
	marked := vgc_count_marked()
	vgc_ph[6] = C.vgc_now_ns()
	vgc_mark_adapt(marked) // cx-home/v#16: the next cycle's marker count
	vgc_grow_gate_prev_marked = C.vgc_atomic_load_u64(&vgc_heap.heap_marked)
	C.vgc_atomic_store_u64(&vgc_heap.heap_marked, marked)
	// Reset heap_live to match what we actually found alive. The per-thread
	// live_delta/alloc_delta (un-flushed accounting) are now stale — `marked` is
	// the true live set — so flush each thread's total-alloc stat and zero both
	// deltas. Safe: the world is stopped, so no mutator is mid-update.
	for ci in 0 .. vgc_heap.ncaches {
		unsafe {
			vgc_heap.total_alloc += vgc_cache(ci).alloc_delta
			vgc_cache(ci).alloc_delta = 0
			vgc_cache(ci).live_delta = 0
		}
	}
	C.vgc_atomic_store_u64(&vgc_heap.heap_live, marked)

	// === Phase 4: Sweep ===
	vgc_heap.sweep_gen++
	C.vgc_atomic_store_u32(&vgc_heap.sweep_done, 0)
	vgc_heap.sweep_idx = 0
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_sweep)

	// Sweep synchronously - it's fast and avoids race conditions
	vgc_watch_snapshot(6) // STAGE 6: immediately pre-sweep (the verdict mark+alloc state)
	$if vgc_closlean ? {
		// #145 deep-fix A: LEAN closure check (SCAN-referrer spans only — see the
		// noscan-skip in vgc_verify_mark_closure). Cheap enough to coexist with bf1.
		vgc_verify_mark_closure()
	}
	$if vgc_closonly ? {
		// #145 deep-fix A: LEAN closure-only oracle. Runs ONLY the marked-referrer →
		// unmarked-referent check (vgc_verify_mark_closure: tags 0xc105 total, 0x5ca0
		// scan-type=definite-bug, + per-edge vgc_verify_report naming holder/victim),
		// WITHOUT the heavy vgc_rootfind_enumerate all-anon-region scan that collapsed
		// throughput to ~3 rps under -d vgc_verify. A closure violation IS the descent
		// miss observed directly (every marked object, not a single sampled watch),
		// under STW. Paired throughput vs cx_coop_det decides whether even this second
		// heap scan masks. Isolated so the rootfind noise/cost can't confound.
		vgc_verify_mark_closure()
	}
	$if vgc_verify ? {
		// DEBUG: verify the mark reached closure before we free anything. Runs
		// fully inside this STW window (world stopped), so it does NOT perturb the
		// mutator/collector timing the residual depends on — unlike per-word probes.
		vgc_verify_mark_closure()
		// DEBUG: locate the missed root for any swept-while-live object by scanning
		// every writable non-arena region (thread stacks / libc heap / anon mmaps)
		// for pointers to allocated-but-unmarked objects.
		vgc_rootfind_count = 0
		C.vgc_rootfind_enumerate(u64(vgc_arena_lo), u64(vgc_arena_hi))
		if vgc_rootfind_count > 0 {
			C.vgc_say(0x4007, u64(vgc_rootfind_count)) // ROOT(find) total this cycle
		}
	}
	// Protect mcache-RESIDENT spans from reclamation this cycle (residual #4 fix — see
	// vgc_protect_cached_spans). MUST run under STW, after mark, before sweep, while
	// gc_cycle still holds THIS cycle's value (it is bumped only after the sweep).
	vgc_protect_cached_spans()
	C.vgc_trace(9, self_idx, u64(vgc_heap.gc_cycle), 0) // SWEEP0
	vgc_do_sweep()
	vgc_ph[7] = C.vgc_now_ns()
	// cx-home/v#16: the three walks' time, for the next cycle's walker count
	vgc_walk_adapt((vgc_ph[1] - vgc_ph[0]) + (vgc_ph[6] - vgc_ph[5]) + vgc_ph_swalk_ns)
	C.vgc_trace(10, self_idx, u64(vgc_heap.gc_cycle), 0) // SWEEP1

	// Drop mcache slots whose cached span sweep just recycled to the pool (and the
	// tiny cursor). Must run while the world is still stopped, after sweep. Without
	// this, threads resume holding pointers to freed/decommitted spans -> reuse breaks
	// (unbounded arena growth) and the next alloc faults. See vgc_fixup_caches.
	vgc_fixup_caches()

	// Advance the cycle counter + recompute the next-GC trigger while the world is
	// STILL STOPPED — BEFORE resume. gc_cycle is read by mutators to stamp a freshly
	// acquired span's `sweep_gen` (vgc_span_alloc / vgc_central_get_span), and the
	// sweep's in-flight guard (vgc_sweep_span) recycles an empty span only when
	// `sweep_gen != gc_cycle`. Bumping gc_cycle AFTER resume left a tiny but real
	// window: a mutator that acquired an empty, still-in-flight span between resume
	// and the bump stamped it with the OLD cycle, so the NEXT cycle's sweep saw
	// `sweep_gen != gc_cycle` and recycled that span out from under the mutator — a
	// use-after-free (the residual sporadic crash under concurrent HTTP load; found
	// with ThreadSanitizer as a gc_cycle race between vgc_gc_start and vgc_span_alloc).
	// The sweep above already ran at the pre-bump cycle, so it still correctly skipped
	// spans acquired during THIS cycle. Doing the bump here closes the window: every
	// post-resume acquisition stamps exactly the cycle the next sweep checks against.
	vgc_update_trigger()
	$if vgc_concurrent ? {
		// cx-private#1910: what the next concurrent cycle's stops are judged by
		if vgc_gc_last_end > vgc_gc_t0 {
			vgc_stw_last_pause_ns = vgc_gc_last_end - vgc_gc_t0
		}
	}
	vgc_gctrace_emit()
	vgc_heap.gc_cycle++
	vgc_heap.total_alloc_at_gc = C.vgc_atomic_load_u64(&vgc_heap.total_alloc)

	vgc_stw_resume(self_idx)

	C.vgc_trace(12, self_idx, u64(vgc_heap.gc_cycle), 0) // GC_END
	vgc_gc_owner = -1
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_off)
}

// vgc_stw_stop stops the world for the collector on this thread (cx-private#1910:
// the one stop both collectors use): the cooperative park wait, the allocator
// locks, the two-pass straggler suspend with safe-region coverage (or, under
// -d vgc_legacy_stw, a mach suspend of every registered thread), the passive
// probe, the work-queue reset and the span-stash drain. On return every other
// mutator is parked, safe or suspended, and this thread holds cache_lock,
// free_spans_lock, vgc_heap.lock, every central lock and the spawn-root lock.
// vgc_wait_cpu_begin / _end bracket one of the collecting thread's waits
// (cx-home/v#42): the CPU the wait spun is added to vgc_gc_wait_cpu, which the
// pacer takes off the cycle's cost. Only the collecting thread calls them.
@[inline]
fn vgc_wait_cpu_begin() u64 {
	if vgc_pacer_wall != 0 || vgc_gc_cpu_t0 == 0 {
		return 0
	}
	return C.vgc_thread_cpu_ns()
}

@[inline]
fn vgc_wait_cpu_end(t0 u64) {
	if t0 != 0 {
		t1 := C.vgc_thread_cpu_ns()
		if t1 > t0 {
			vgc_gc_wait_cpu += t1 - t0
		}
	}
}

fn vgc_stw_stop(self_idx int) {
	$if !vgc_legacy_stw ? {
		// #63 COOPERATIVE STW (DEFAULT; -d vgc_legacy_stw reverts to legacy mach-suspend-all):
		// request a cooperative stop; each RUNNING
		// mutator self-parks at the alloc-path poll (vgc_d_vgc.c.v:1407 -> vgc_safepoint ->
		// vgc_park_spill), self-spilling its own callee-saved registers onto its own
		// scanned stack — the SAME sound shape as the collector's setjmp self-scan
		// (vgc_run_gc_spilled). This removes the arbitrary-PC EXTERNAL register scan that is
		// the residual #63 root miss. Threads not reaching a poll within the bounded wait
		// (blocked in a syscall — thread_get_state capture PROVEN complete, GAP-1 — or in a
		// tight non-allocating loop) are mach-suspended as a fallback. Lock order: hold NO
		// allocator lock while waiting (else an allocating thread blocks before it can
		// reach the poll), take them AFTER, then mach-suspend stragglers (which, being
		// non-allocating/blocked, hold no allocator lock — preserving the
		// no-frozen-lock-holder invariant).
		C.vgc_mutex_lock(&vgc_heap.cache_lock) // registration gate (held across the cycle)
		C.vgc_atomic_store_u32(&vgc_heap.gc_stopped_count, 0)
		// Bump the stop-cycle generation BEFORE raising the flag: a parker that
		// enters because it saw the flag reads the seq of THIS cycle. The suspend
		// loop below trusts stopped==1 only with a matching park_seq — a stale
		// park from the previous back-to-back cycle is a WAKING (running) thread
		// and is signal-suspended like any straggler (#57/#58/#63/#145).
		_ = C.vgc_atomic_add_u32(&vgc_heap.gc_stop_seq, 1)
		C.vgc_atomic_store_u32(&vgc_heap.gc_stop_flag, 1)
		// cx #316: threads inside a GC-safe blocking region are excluded from the
		// park-wait target — they never reach an alloc poll while parked, so
		// counting them only burns the plateau budget every cycle. The load of
		// `safe` is AFTER the seq_cst gc_stop_flag store above (the Dekker pairing
		// with vgc_safe_exit_handshake), and this count is a wait HEURISTIC only:
		// authoritative coverage is the suspend loop below, which re-derives every
		// thread's state. vgc_safe_cov[] is reset here (collector-exclusive under
		// cache_lock) and set at the authoritative read.
		mut want := u32(0)
		for i in 0 .. vgc_heap.ncaches {
			mut c := unsafe { vgc_cache(i) }
			c.cov_safe = false
			c.cov_req = false
			c.cov_susp = false
			if c.registered && i != self_idx && c.mach_port != 0
				&& C.vgc_atomic_load_u32(&vgc_cache(i).safe) == 0 {
				want++
			}
		}
		// Bounded wait: an ACTIVELY-ALLOCATING thread (the victim MatchEnv.clone path)
		// polls vgc_maybe_gc constantly and self-parks within microseconds; a thread
		// blocked in a syscall (kevent/recv) or a tight non-allocating loop never reaches
		// the poll, so waiting for it is pure waste — it is mach-suspended below. Keep the
		// wait short (just long enough for allocating threads to hit their next poll) so the
		// per-GC cost stays negligible. (20M spun ~tens of ms EVERY GC because an idle
		// listener thread never parks -> ~1.8x single-reactor slowdown; 200k is ~100x less.)
		$if vgc_wait_full ? {
			// #145 DIAGNOSTIC DISCRIMINATOR (quiescence wait): give EVERY running
			// mutator unbounded time to self-park (self-spill) instead of being
			// mach-suspended at an arbitrary PC and scanned by the legacy external
			// scanner. Wait until either all registered threads parked OR the parked
			// count plateaus for a long stretch — a plateau means the remaining
			// threads are syscall-blocked (idle listener) / tight non-allocating
			// loops, which never reach a poll and are mach-suspended below (sound for
			// syscall-blocked per GAP-1). If the sweep-while-live oracle goes SILENT
			// under this build (paired vs the bounded default), the root cause is the
			// mach-suspend-of-a-running-mutator external-scan fallback (H1).
			mut last := u32(0xffffffff)
			mut stable := u64(0)
			for C.vgc_atomic_load_u32(&vgc_heap.gc_stopped_count) < want {
				cur := C.vgc_atomic_load_u32(&vgc_heap.gc_stopped_count)
				if cur == last {
					stable++
					if stable > u64(200000000) {
						break
					}
				} else {
					stable = 0
					last = cur
				}
				C.vgc_atomic_fence()
			}
		} $else {
			// Bounded wait: an ACTIVELY-ALLOCATING thread polls vgc_maybe_gc constantly
			// and self-parks within microseconds; a syscall-blocked / tight-loop thread
			// never reaches the poll, so it is mach-suspended below. Keep it short so the
			// per-GC cost stays negligible.
			// PLATEAU early-exit (#71): `want` counts EVERY other registered mutator,
			// including permanently-blocked ones (main in thread-join, idle listeners in
			// kevent) that will never park — with any such thread present the plain
			// bounded wait burned the FULL spin budget every cycle, a fixed ~ms of pause
			// regardless of heap size. That floor fed the adaptive pacer's overhead
			// measurement and dragged the headroom (and RSS) up for programs whose GC
			// work is otherwise tiny. Instead, once the parked count stops advancing for
			// a stretch generously longer than any allocating thread's inter-poll gap
			// (a span refill is at most ~1024 bump allocations away), the remaining
			// threads are blocked/non-allocating by construction — stop waiting and
			// mach-suspend them (the designed-sound straggler path, GAP-1).
			// Plateau size: an allocating thread's worst-case inter-poll gap is one
			// span refill away (~1024 bump allocations, ~tens of us); 2000 pause-loop
			// iterations comfortably covers it while keeping the no-parker exit under
			// ~0.1 ms. cpu_pause, not a seq_cst fence: the acquire load already gives
			// the needed ordering, and 20k fence iterations alone cost ~1 ms of pause.
			mut spins := 0
			mut stable := 0
			mut last_stopped := u32(0xffffffff)
			wcpu := if C.vgc_atomic_load_u32(&vgc_heap.gc_stopped_count) < want {
				vgc_wait_cpu_begin()
			} else {
				u64(0)
			}
			for C.vgc_atomic_load_u32(&vgc_heap.gc_stopped_count) < want && spins < 200000 {
				cur := C.vgc_atomic_load_u32(&vgc_heap.gc_stopped_count)
				if cur != last_stopped {
					last_stopped = cur
					stable = 0
				} else {
					stable++
					if stable > 2000 {
						break
					}
				}
				C.vgc_cpu_pause()
				spins++
			}
			vgc_wait_cpu_end(wcpu)
		}
		// Now safe to take allocator locks (parkers hold none at the poll site) + finish
		// any lazy sweep from the previous cycle.
		C.vgc_mutex_lock(&vgc_heap.free_spans_lock)
		vgc_sweep_finish()
		C.vgc_mutex_lock(&vgc_heap.lock)
		for i in 0 .. 136 {
			C.vgc_mutex_lock(&vgc_heap.central[i].lock)
		}
		// SPAWN-ROOT LOCK, same lock-before-suspend discipline (#57/#58/#63/#145
		// ROOT CAUSE): the spawn-roots loop below iterated UNLOCKED on the belief
		// that "the world is stopped, so no mutator can be mid add/remove" — but a
		// DYING worker's exit path (thread_wrapper tail: vgc_spawn_root_remove)
		// runs with NO safepoint and can be past signal delivery (ESRCH => the
		// suspend loop rightly skips it). Its swap-remove moves the LAST entry
		// into a slot the iteration already passed => that entry — a STARTING
		// worker's arg struct carrying its cloned bindings/closures maps — is
		// never shaded => its keys arrays are swept => the new worker begins on
		// freed maps (string_clone segfault; victim = binding-key/worker-name
		// buffers). Holding the lock across the cycle makes the dying thread's
		// remove wait until after the resume, closing the race. Deadlock-free:
		// remove/add hold ONLY this lock, never allocate, never poll, so no
		// frozen holder exists (acquired before any suspension, like the rest).
		C.vgc_mutex_lock(&vgc_spawn_root_lock)
		// Mach-suspend only stragglers (registered, not self, not self-parked). Allocator
		// locks are held first, so a straggler cannot be frozen holding one.
		// Pass 1 (v#28): decide, and REQUEST every suspend (no ack waited here).
		for i in 0 .. vgc_heap.ncaches {
			mut c := unsafe { vgc_cache(i) }
			C.vgc_trace(6, i, if c.registered { u64(1) } else { u64(0) }, u64(c.mach_port))
			if c.registered && i != self_idx && c.mach_port != 0
				&& (C.vgc_atomic_load_u32(&vgc_cache(i).stopped) == 0
				|| c.park_seq != C.vgc_atomic_load_u32(&vgc_heap.gc_stop_seq)) {
				// cx #316: the AUTHORITATIVE safe-region read. A thread seen safe==1
				// here holds no in-flight GC state (contract at vgc_safe_enter_spill):
				// its roots are its entry-time stack prefix (already in stack_lo/hi)
				// plus its safe_regs snapshot — skip suspension entirely. Ordering:
				// this load is after the seq_cst gc_stop_flag store, so a thread
				// waking concurrently either published safe=0 first (seen here ->
				// mach-suspended below as a straggler mid-handshake, externally
				// scanned) or reads gc_stop_flag==1 in its exit handshake and blocks
				// until resume — it can never run through mark+sweep uncovered.
				// vgc_safe_cov[] snapshots the decision so the root scan and the
				// passive probe treat exactly the same set as covered.
				if C.vgc_atomic_load_u32(&vgc_cache(i).safe) != 0 {
					c.cov_safe = true
					continue
				}
				// stopped==1 counts ONLY with a matching park_seq: a stale park from
				// the previous cycle is a WAKING thread that will run through this
				// GC — suspend it like any straggler. cov_susp (pass 2) reflects the
				// ACK, not the attempt: an un-acked target is a gone thread (safe to
				// skip), never a running mutator (the settle waits for live targets).
				c.cov_req = C.vgc_suspend_request(i, c.mach_port) != 0
				$if vgc_serial_suspend ? {
					// A/B lever (cx-home/v#28 bisect): settle each slot right after
					// its request — the pre-two-pass interleaving.
					if c.cov_req {
						c.cov_req = false
						c.cov_susp = C.vgc_suspend_settle(i, c.mach_port) != 0
						if c.cov_susp {
							vgc_stat_mach_suspends++
						}
					}
				}
			}
		}
		// Pass 2: settle every requested suspend (ack / register capture). The
		// settle spins for the acks: its CPU is a wait (cx-home/v#42).
		wcpu2 := vgc_wait_cpu_begin()
		for i in 0 .. vgc_heap.ncaches {
			mut c := unsafe { vgc_cache(i) }
			if c.cov_req {
				c.cov_susp = C.vgc_suspend_settle(i, c.mach_port) != 0
				if c.cov_susp {
					vgc_stat_mach_suspends++
				}
				C.vgc_trace(7, i, u64(c.mach_port), 0)
			}
		}
		vgc_wait_cpu_end(wcpu2)
	} $else {
		C.vgc_atomic_store_u32(&vgc_heap.gc_stop_flag, 0) // OS-suspend, not cooperative

		// Serialize thread registration/deregistration with STW: hold cache_lock across the
		// whole cycle. Acquired BEFORE any suspend (no holder frozen); blocks new
		// register/exit until the cycle ends (the create-vs-STW white-allocation race).
		C.vgc_mutex_lock(&vgc_heap.cache_lock)

		// Acquire EVERY allocator lock BEFORE stopping the world, so no mutator is ever
		// mach-suspended mid-critical-section (the thread-churn segv class). The collector
		// never re-enters vgc_heap.lock / central[].lock (mutator-only) and already holds
		// free_spans_lock, so acquisition order is deadlock-free.
		C.vgc_mutex_lock(&vgc_heap.lock)
		for i in 0 .. 136 {
			C.vgc_mutex_lock(&vgc_heap.central[i].lock)
		}
		C.vgc_mutex_lock(&vgc_spawn_root_lock) // see the cooperative branch above

		for i in 0 .. vgc_heap.ncaches {
			// cx #316: the legacy mach-suspend collector deliberately IGNORES safe
			// regions — it suspends every registered thread (a safe thread is just a
			// blocked thread; suspending it is today's proven-sound behavior) and
			// scans everyone externally. Reset the coverage snapshot so the shared
			// root-scan path takes the external branch for all of them.
			mut c := unsafe { vgc_cache(i) }
			c.cov_safe = false
			c.cov_req = false
			c.cov_susp = false
			reg := if c.registered { u64(1) } else { u64(0) }
			C.vgc_trace(6, i, reg, u64(c.mach_port)) // SUSP? (decision inputs for EVERY slot)
			if c.registered && i != self_idx && c.mach_port != 0 {
				c.cov_req = C.vgc_suspend_request(i, c.mach_port) != 0
			}
		}
		wcpu2 := vgc_wait_cpu_begin()
		for i in 0 .. vgc_heap.ncaches {
			mut c := unsafe { vgc_cache(i) }
			if c.cov_req {
				// cov_susp reflects the ACK (see the cooperative branch above).
				c.cov_susp = C.vgc_suspend_settle(i, c.mach_port) != 0
				if c.cov_susp {
					vgc_stat_mach_suspends++
				}
				C.vgc_trace(7, i, u64(c.mach_port), 0) // SUSP! (actually suspended)
			}
		}
		vgc_wait_cpu_end(wcpu2)
	}
	$if vgc_passive ? {
		// #145 LIGHT non-masking STW-completeness probe: at mark time every registered
		// peer must be either self-parked (stopped==1) or mach-suspended (susp[i]). Any
		// peer that is registered, not self, has a mach_port, yet is NEITHER ran free
		// during mark -> its live roots were never scanned (the smoking gun for a
		// sweep-while-live). O(ncaches), once per GC, emits only on anomaly -> no
		// per-word cost, cannot mask the race.
		mut uncovered := u32(0)
		for i in 0 .. vgc_heap.ncaches {
			c := unsafe { vgc_cache(i) }
			if c.registered && i != self_idx && c.mach_port != 0 {
				parked_now := C.vgc_atomic_load_u32(&vgc_cache(i).stopped) != 0
					&& c.park_seq == C.vgc_atomic_load_u32(&vgc_heap.gc_stop_seq)
				// cx #316: a safe-region thread is covered by its entry-time
				// stack prefix + register snapshot (vgc_safe_cov, the suspend
				// loop's authoritative decision), not by park or suspension.
				if !parked_now && !c.cov_susp && !c.cov_safe {
					uncovered++
				}
			}
		}
		if uncovered != 0 {
			C.vgc_say(0x57ab, u64(uncovered)) // STW-anomaly: peers running free during mark
		}
	}
	// work_lock is re-entered by vgc_work_put/get during mark; no mutator holds it
	// under full-STW (the write barrier never fires while mutators are frozen), so a
	// plain reset is enough (it is not pre-acquired since the collector re-enters it).
	C.vgc_atomic_store_u32(&vgc_heap.work_lock, 0)
	// cx-private#1910: the parked and safe threads' span stashes return to the
	// pool (free_spans_lock is held, the world is stopped), so the trim, the
	// defrag and the trace line below see the whole free set.
	vgc_tpool_drain_stw(self_idx)
	// cx-home/v#36: a thread inside a GC-safe region gives up its cached spans.
	vgc_safe_cache_drain_stw()
}

// vgc_safe_cache_drain_stw drops the span cache of every thread that is inside a
// GC-safe region at this stop (cov_safe), the shape of a parked channel worker.
// Each class it allocated in left a fresh span in its cache, a few objects into
// 8 KB. 10,000 parked workers kept ~10 spans each (1.25 GB against a 63 MB live
// set), and no other thread could allocate into their free slots (cx-home/v#36).
// A dropped span is the B18 case of vgc_cache_get_span: it stays in allspans,
// and this cycle's sweep returns it to circulation. An empty span goes to the
// free-span pool, and a partly used one is relinked onto central.partial, where
// the next refill of that class (any thread's) takes it. The tiny cursor goes too:
// its block is an allocated object that is swept like any other once nothing
// roots it. SOUND: by the safe-region contract the thread allocates nothing until
// it leaves, and it holds no span pointer across the region (it entered outside
// the allocator). A thread parked at the allocation poll (stopped) or
// mach-suspended (cov_susp) may be frozen mid-carve, so its cache is left alone.
// The drain runs at the stop, before vgc_protect_cached_spans stamps the cached
// spans, so the dropped spans are swept this cycle. On leaving the region the
// thread refills each class it touches from central, once.
fn vgc_safe_cache_drain_stw() {
	for i in 0 .. vgc_heap.ncaches {
		mut c := unsafe { vgc_cache(i) }
		if !c.registered || !c.cov_safe {
			continue
		}
		for sc in 0 .. 136 {
			unsafe {
				c.alloc[sc] = nil
			}
		}
		c.tiny = 0
		c.tiny_offset = 0
	}
}

// vgc_stw_resume releases the locks vgc_stw_stop took (reverse order), lets the
// cooperative parkers go and resumes exactly the slots the stop suspended.
fn vgc_stw_resume(self_idx int) {
	// Mark + sweep done — release every allocator lock held across the cycle before
	// resuming, so resumed mutators don't block on them. (Reverse acquisition order.)
	C.vgc_mutex_unlock(&vgc_spawn_root_lock)
	for i in 0 .. 136 {
		C.vgc_mutex_unlock(&vgc_heap.central[i].lock)
	}
	C.vgc_mutex_unlock(&vgc_heap.lock)
	C.vgc_mutex_unlock(&vgc_heap.free_spans_lock)

	$if !vgc_legacy_stw ? {
		// Release the cooperative parkers: they spin on gc_stop_flag, and the allocator
		// locks are already released above, so they will not block on resume. susp[] (set
		// only for mach-suspended stragglers) is the authoritative resume set, so clearing
		// gc_stop_flag here cannot confuse the resume loop below.
		C.vgc_atomic_store_u32(&vgc_heap.gc_stop_flag, 0)
		// cx-private#1893: parkers past their spin sleep on the flag (vgc_wait_flag_clear).
		C.vgc_wake_flag_waiters(&vgc_heap.gc_stop_flag)
	}

	// Resume the world: mark + sweep are complete, every live object survived, and
	// gc_cycle/trigger are already advanced (above) so resumed mutators stamp spans
	// with the correct cycle. Resume exactly the slots THIS cycle mach-suspended
	// (susp[]); cooperative parkers are released via gc_stop_flag above.
	C.vgc_atomic_fence()
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { vgc_cache(i) }
		if c.cov_susp {
			C.vgc_resume_slot(i, c.mach_port)
			C.vgc_trace(11, i, u64(c.mach_port), 0) // RESUME
		}
	}
	C.vgc_mutex_unlock(&vgc_heap.cache_lock) // release the registration gate
}

// ============================================================
// Concurrent mark (vgc_concurrent, the `-gc e` default since cx-private#1910;
// `-d vgc_stw` builds the stop-the-world collector above) — mark while
// mutators run.
// ============================================================
//
// The cycle has two stops, both the cooperative stop of vgc_stw_stop (park
// at the allocation poll, safe regions, two-pass straggler suspend):
//   (1) START: sweep_finish, clear marks, every thread's roots (suspended
//       registers, data segments, stacks, spawn roots, pins) into the grey
//       set, barrier on, resume.
//   (2) the MIDDLE, world running: the markers drain the grey set (the pool
//       when the plan says so). A mutator's pointer store into a heap object
//       dirties that object's span first (vgc_wb_store, codegen + the builtin
//       bulk mutators); an object born in a scan span sets the span's `born`
//       flag and its own mark bit (vgc_alloc_black_hook) — alloc-GRAY: the
//       object survives this cycle AND its span is re-scanned at termination,
//       so whatever filled it after the hook (decl_assign stores, memdup,
//       realloc's copy, HEAP_vgc) is seen without a barrier.
//   (3) TERMINATION, stopped: the roots again (the stacks moved), every span
//       with dirty or born set re-scanned object by object, the final drain,
//       barrier off, count, protect, sweep (parallel walkers), fixup, trigger,
//       resume. Dirty and born are cleared here only: a concurrent pre-pass
//       that cleared them would race the dirty-BEFORE-store barrier (dirty,
//       pass clears + scans, store lands clean) — unsound under preemption.
// Soundness rests on: every pointer store into a heap object outside the
// codegen barrier is in a builtin that calls vgc_wb_store (array, map,
// channels, arrays.copy); `-d vgc_cm_verify` re-marks the heap from scratch
// under the termination stop and names every object the concurrent mark
// missed (0x1910), the oracle the door and the suite ran under.

// cx-private#1910 cut 1: the births a concurrent middle would see, predicted
// from the allocation since the last cycle over its interval (the rate) times
// the last mark's wall, against twice the born bound (VGC_CM_BORN_PCT of the
// live set, at least 4 MB; 0 = no bound, always fits): the cut's own
// overshoot is about a bound (the stop's latency times the rate), so a probe
// forecast past two bounds would be cut at once and leave that much floating
// garbage for nothing. Read at the trigger, before the stop: the per-thread
// deltas are a racy read, the rate an estimate — the cut (vgc_cm_cut) is the
// bound's guarantee, this is its forecast, so a probe known to lose on space
// is not run. The forecast is deliberately not stricter: a loaded box
// stretches the stop-the-world mark (the door's 22 ms at load 40 against 5 ms
// quiet), and a forecast of twice that mark against one bound sent the door
// — the workload the concurrent cycle is for — to stop-the-world cycles,
// pause p50 1.6 -> 25 ms.
fn vgc_cm_born_fits() bool {
	if vgc_cm_born_pct == 0 || vgc_gc_last_end == 0 {
		return true
	}
	now := C.vgc_now_ns()
	if now <= vgc_gc_last_end {
		return true
	}
	interval := now - vgc_gc_last_end
	mut since := C.vgc_atomic_load_u64(&vgc_heap.total_alloc)
	for ci in 0 .. vgc_heap.ncaches {
		since += unsafe { vgc_cache(ci).alloc_delta }
	}
	if since <= vgc_heap.total_alloc_at_gc {
		return true
	}
	since -= vgc_heap.total_alloc_at_gc
	mut bound := C.vgc_atomic_load_u64(&vgc_heap.heap_marked) * vgc_cm_born_pct / 100
	if bound < vgc_cm_born_min {
		bound = vgc_cm_born_min
	}
	// since x mark / interval, without overflow: the rate in bytes per
	// millisecond first
	rate_per_ms := since / (interval / 1000000 + 1)
	pred := rate_per_ms * (vgc_mark_last_ns / 1000000 + 1)
	return pred <= 2 * bound
}

// cx-private#1910: this cycle's stop-the-world time (the two windows), the
// `pause=` the trace line reports under the concurrent collector; the pacer
// keeps the whole cycle as its cost (conservative).
__global vgc_cm_pause_ns = u64(0)
// true while the cycle being paced is a concurrent one (the trace line's pause)
__global vgc_cm_this_cycle = false
__global vgc_cm_stop1_ns = u64(0)
__global vgc_cm_middle_ns = u64(0)
__global vgc_cm_stop2_ns = u64(0)
__global vgc_cm_rescan_ns = u64(0)
__global vgc_cm_rescan_spans = u64(0)
__global vgc_cm_rescan_objs = u64(0)
__global vgc_cm_verify_missed = u64(0)

// Re-scan every span the barrier dirtied or an allocation touched during the
// concurrent middle: each allocated object's words are shaded (a superset of
// the Dijkstra insertion barrier's exact referent), so a white object stored
// into a black one, or filled into a black newborn, is found. Under the
// termination stop; clears both flags.
@[markused]
fn vgc_rescan_dirty_spans(term bool) {
	$if vgc_cm_nobarrier ? {
		// TEETH KNOB (testing only): skip the re-scan, i.e. no barrier. The
		// soundness gate (cm_stress) must reproduce live reclamation with it.
		return
	}
	for w in 0 .. vgc_max_markers {
		vgc_rescan_sum[w * 16] = 0
		vgc_rescan_sum[w * 16 + 1] = 0
		vgc_rescan_sum[w * 16 + 2] = 0
	}
	vgc_rescan_term = term
	C.vgc_atomic_store_u32(&vgc_walk_cursor, 0)
	// cx-home/v#52: at eight allocating threads the termination re-scan was
	// one thread walking every span they dirtied or allocated into (2.5 ms of
	// a 3.5 ms stop, 3,000 objects a cycle) while the pool idled and every
	// mutator waited; the spans are disjoint, so each pool thread takes a
	// stripe of the span table and shades into its own work buffer
	n := vgc_rescan_nworkers_cur
	if n <= 1 || vgc_mark_pool_n == 0 {
		vgc_rescan_walk(0, 1)
	} else {
		vgc_pool_run(vgc_pool_phase_rescan, n)
	}
	mut spans := u64(0)
	mut objs := u64(0)
	mut young := u64(0)
	for w in 0 .. vgc_max_markers {
		spans += vgc_rescan_sum[w * 16]
		objs += vgc_rescan_sum[w * 16 + 1]
		young += vgc_rescan_sum[w * 16 + 2]
	}
	vgc_cm_rescan_spans = spans
	vgc_cm_rescan_objs = objs
	vgc_perm_young_objs = young
}

// One thread's share of the re-scan (vgc_rescan_dirty_spans): it claims
// vgc_rescan_chunk words of inuse_bits at a time from the shared cursor and
// touches only the spans of its claims — their dirty and born flags, their
// cards and young bits — and shades into its own work buffer (w), which a
// pool thread publishes to the shared list before it reports the phase done
// (the drain that follows may run on fewer markers than the re-scan had).
fn vgc_rescan_walk(w int, n int) {
	term := vgc_rescan_term
	nb := u32((vgc_heap.nspans + 7) / 8)
	mut spans := u64(0)
	mut objs := u64(0)
	mut young := u64(0)
	for {
		w1 := C.vgc_atomic_add_u32(&vgc_walk_cursor, vgc_rescan_chunk)
		w0 := w1 - vgc_rescan_chunk
		if w0 >= nb {
			break
		}
		hi := if w1 < nb { w1 } else { nb }
		for wi in w0 .. hi {
			mut bits := unsafe { vgc_heap.inuse_bits[int(wi)] }
			for bits != 0 {
				bi := C.vgc_ctz8(bits)
				bits &= bits - 1
				span := unsafe { vgc_heap.allspans[int(wi) * 8 + bi] }
				if span == unsafe { nil } || !span.in_use {
					continue
				}
				mut dirty := C.vgc_atomic_load_u32(&span.dirty) != 0
					|| C.vgc_atomic_load_u32(&span.born) != 0
				if span.perm != 0 && span.perm_bits != unsafe { nil } && !span.noscan {
					if vgc_perm_cards_take(span) {
						dirty = true
					}
					// cx-home/v#15: a permanent span. Dirtied since the last stop: its
					// PERMANENT objects are scanned (every other object in it is traced
					// or swept as usual — scanning a dead one would keep what it points
					// to; at a concurrent termination every allocated object, as any
					// dirty span: a black young object mutated in the middle) and
					// young_bits re-taken; clean: only the permanent objects young_bits
					// names (they hold a pointer to a non-permanent object, which only
					// they keep alive).
					ps, po, py := vgc_rescan_perm_span(span, dirty, term, w)
					spans += ps
					objs += po
					young += py
					if dirty {
						unsafe {
							C.vgc_atomic_store_u32(&(&VGC_Span(span)).dirty, 0)
							C.vgc_atomic_store_u32(&(&VGC_Span(span)).born, 0)
						}
					}
					continue
				}
				if !dirty {
					continue
				}
				unsafe {
					C.vgc_atomic_store_u32(&(&VGC_Span(span)).dirty, 0)
					C.vgc_atomic_store_u32(&(&VGC_Span(span)).born, 0)
				}
				if span.noscan || span.alloc_bits == unsafe { nil } {
					continue
				}
				spans++
				nbytes := (span.nelems + 7) / 8
				for b in 0 .. nbytes {
					alloc_byte := unsafe { span.alloc_bits[b] }
					if alloc_byte == 0 {
						continue
					}
					for bit in 0 .. 8 {
						idx := u32(b) * 8 + u32(bit)
						if idx >= span.nelems {
							break
						}
						if (alloc_byte & (u8(1) << u32(bit))) != 0 {
							objs++
							obj_addr := span.base + usize(idx) * usize(span.elem_size)
							vgc_scan_range(obj_addr, obj_addr + usize(span.elem_size), w)
						}
					}
				}
			}
		}
	}
	vgc_rescan_sum[w * 16] = spans
	vgc_rescan_sum[w * 16 + 1] = objs
	vgc_rescan_sum[w * 16 + 2] = young
	if w > 0 {
		vgc_work_flush_local(w)
	}
}

// cx-home/v#52: this cycle's re-scan thread count, planned before stop 1 (the
// pool grows outside a stop): one thread per quarter of vgc_mark_par_min_ns
// of the last re-scan's work, up to the marker configuration and the CPUs
// the rest of the box leaves free (the walks' load gate: a preempted thread
// holds its claim through the join); serial in a fork child and under the
// diagnostic builds whose shade path writes shared counters.
fn vgc_rescan_plan() int {
	if vgc_mark_workers_cfg <= 1 || vgc_mark_forked || vgc_watch_addr != 0 {
		return 1
	}
	$if vgc_rootdiag ? {
		return 1
	}
	$if vgc_birthcheck ? {
		return 1
	}
	$if vgc_passive ? {
		return 1
	}
	q := vgc_mark_par_min_ns / 4
	mut total := if q == 0 {
		vgc_mark_workers_cfg
	} else {
		int(vgc_rescan_last_work_ns / q)
	}
	if total > vgc_mark_workers_cfg {
		total = vgc_mark_workers_cfg
	}
	if vgc_walk_load_gate {
		if C.vgc_box_busy(vgc_walk_ncpu) != 0 {
			return 1
		}
		free_cpus := C.vgc_box_free_cpus(vgc_walk_ncpu,
			int(C.vgc_atomic_load_u32(&vgc_heap.live_threads)))
		if total > free_cpus {
			total = free_cpus
		}
	}
	if total <= 1 {
		return 1
	}
	return vgc_pool_ensure(total)
}

// vgc_perm_cards_take reads and clears the cards of a permanent span's pages
// (STW): true when a store landed in the span since the last stop.
fn vgc_perm_cards_take(span &VGC_Span) bool {
	if vgc_perm_cards == unsafe { nil } || span.base < vgc_perm_lo {
		return false
	}
	first := (span.base - vgc_perm_lo) / vgc_page_size
	mut any := false
	for k in 0 .. usize(span.npages) {
		pg := first + k
		if pg >= vgc_perm_cards_n {
			break
		}
		if unsafe { vgc_perm_cards[pg] } != 0 {
			any = true
			unsafe {
				vgc_perm_cards[pg] = 0
			}
		}
	}
	return any
}

// vgc_scan_perm_obj scans one object's words as vgc_scan_range does (every
// heap pointer shaded) and reports whether any of them refers to an allocated
// object outside the permanent generation (cx-home/v#15).
fn vgc_scan_perm_obj(lo usize, hi usize, w int) bool {
	mut young := false
	start := (lo + sizeof(usize) - 1) & ~(usize(sizeof(usize)) - 1)
	mut addr := start
	for addr + sizeof(usize) <= hi {
		val := unsafe { *(&usize(voidptr(addr))) }
		addr += sizeof(usize)
		if val < vgc_arena_lo || val >= vgc_arena_hi {
			continue
		}
		sp := vgc_find_span(voidptr(val))
		if sp == unsafe { nil } || !sp.in_use || sp.elem_size == 0 {
			continue
		}
		idx := u32((val - sp.base) / usize(sp.elem_size))
		if idx >= sp.nelems || sp.alloc_bits == unsafe { nil }
			|| C.vgc_bitmap_get(sp.alloc_bits, idx) == 0 {
			continue
		}
		if sp.perm != 0 && sp.perm_bits != unsafe { nil } && C.vgc_bitmap_get(sp.perm_bits, idx) != 0 {
			continue // a permanent object: black already
		}
		young = true
		vgc_shade(val, w)
	}
	return young
}

// One permanent span's re-scan (see vgc_rescan_dirty_spans). young_bits is a
// subset of perm_bits: only a permanent object is a root for what it points to.
fn vgc_rescan_perm_span(span &VGC_Span, dirty bool, term bool, w int) (u64, u64, u64) {
	mut spans := u64(0)
	mut objs := u64(0)
	mut young := u64(0)
	if span.alloc_bits == unsafe { nil } {
		return 0, 0, 0
	}
	yb := vgc_young_bits(span)
	nbytes := (span.nelems + 7) / 8
	mut counted := false
	for b in 0 .. nbytes {
		pbyte := unsafe { span.perm_bits[b] }
		sel := if !dirty {
			unsafe { yb[b] }
		} else if term {
			unsafe { span.alloc_bits[b] }
		} else {
			unsafe { span.alloc_bits[b] } & pbyte
		}
		if sel == 0 {
			continue
		}
		if !counted {
			spans++
			counted = true
		}
		mut nyb := u8(0)
		for bit in 0 .. 8 {
			idx := u32(b) * 8 + u32(bit)
			if idx >= span.nelems {
				break
			}
			m := u8(1) << u32(bit)
			if (sel & m) == 0 {
				continue
			}
			obj_addr := span.base + usize(idx) * usize(span.elem_size)
			if vgc_scan_perm_obj(obj_addr, obj_addr + usize(span.elem_size), w) && (pbyte & m) != 0 {
				nyb |= m
				young++
			}
			if dirty {
				objs++
			}
		}
		if dirty {
			unsafe {
				yb[b] = nyb
			}
		}
	}	return spans, objs, young
}

// The roots, as both stops take them: the suspended threads' registers and
// refreshed ranges, the data segments, the cache slots, every stack, the
// spawn-argument structs and the pins.
fn vgc_cm_roots(self_idx int) {
	// the phase stamps vgc_mark_roots sets belong to stop 1 (the phases line)
	ph3 := vgc_ph[3]
	ph4 := vgc_ph[4]
	vgc_scan_suspended_roots(self_idx)
	vgc_mark_roots()
	vgc_ph[3] = ph3
	vgc_ph[4] = ph4
	for i in 0 .. vgc_nspawn_roots {
		vgc_shade_spawn_root(usize(unsafe { vgc_spawn_roots[i] }))
	}
}

// The grey set drained to empty: on the pool when this cycle's plan has
// markers, else by this thread.
fn vgc_cm_drain() {
	if vgc_mark_nworkers_cur > 1 {
		vgc_work_flush_local(0)
		vgc_pool_run(vgc_pool_phase_mark, vgc_mark_nworkers_cur)
	}
	vgc_drain_mark_work(0)
}

// vgc_perm_promote (cx-home/v#15 lever 2): under the stop of a stop-the-world
// cycle, after its mark reached closure, every marked object becomes
// permanent: its span's perm_bits take the mark bits, and from now on the
// clear walk starts the span's mark bits from them (the object is black at
// the start of every cycle, never pushed, never traced, never swept) and the
// barrier regime is on (wb_enabled bit 1): a pointer store into a permanent
// span dirties it, and vgc_rescan_dirty_spans scans the span's objects at the
// next stop, so a pointer from a permanent object into a later generation is
// found there. Soundness: (1) every pointer a permanent object held at the
// promotion was traced by this cycle, so its referents are permanent too;
// (2) a pointer stored later goes through the barrier, called before and
// after the store — the dirty bit is set when the store lands or is set
// again after it (a cycle that cleared the bit between the two calls ran
// with the store not yet visible; the call after the store sets it again),
// so the next stop re-scans the span; (3) the only mutator-side store the
// codegen barrier does not cover is the initialization of a fresh object
// (decl_assign, memdup, the realloc copy), which is never a permanent
// object's — a freed permanent slot leaves the generation in vgc_free before
// it can be reused; (4) the span is dirtied by its address, so a store
// through an interior pointer (an array header inside a permanent struct) is
// covered as any other. -d vgc_cm_verify re-marks every cycle from zero and
// counts what the permanent scheme would have missed (vgc_cm_verify).
fn vgc_perm_promote() {
	$if vgc_concurrent ? {
		mut nsp := u64(0)
		mut nbytes_total := u64(0)
		mut lo := vgc_perm_lo
		mut hi := vgc_perm_hi
		// vgc_set_permanent's epoch: only the marked candidates (allocated
		// before the call) are promoted; without one (VGC_PERM_CYCLE=N) the
		// whole marked set is, as before
		epoch := vgc_perm_epoch
		for i in 0 .. vgc_heap.nspans {
			span := unsafe { vgc_heap.allspans[i] }
			if span == unsafe { nil } || !span.in_use || span.mark_bits == unsafe { nil } {
				continue
			}
			if epoch && span.perm_cand == unsafe { nil } {
				continue
			}
			nb := (span.nelems + 7) / 8
			mut any := u8(0)
			for b in 0 .. nb {
				any |= unsafe { span.mark_bits[b] } & (if epoch {
					unsafe { span.perm_cand[b] }
				} else {
					u8(0xff)
				})
			}
			if any == 0 {
				continue
			}
			if span.perm_bits == unsafe { nil } {
				pb := vgc_perm_bits_alloc()
				if pb == unsafe { nil } {
					continue
				}
				unsafe {
					(&VGC_Span(span)).perm_bits = pb
				}
			}
			was := span.perm != 0
			unsafe {
				if epoch {
					for b in 0 .. nb {
						v := span.mark_bits[b] & span.perm_cand[b]
						pp := &u8(voidptr(usize(span.perm_bits) + usize(b)))
						*pp = if was { *pp | v } else { v }
					}
				} else {
					C.memcpy(span.perm_bits, span.mark_bits, nb)
				}
				C.memset(vgc_young_bits(span), 0, 136)
				(&VGC_Span(span)).perm = 1
				if epoch {
					// a marked object born after the epoch stays young, and a
					// promoted one may point at it: the next stop re-scans the
					// span's permanent objects and takes young_bits from them
					C.vgc_atomic_store_u32(&(&VGC_Span(span)).dirty, 1)
				} else {
					// every pointer the span holds was traced by this cycle and
					// every marked object is promoted: nothing young is
					// referenced yet; a mutator suspended between its barrier
					// call and its store sets the bit again
					C.vgc_atomic_store_u32(&(&VGC_Span(span)).dirty, 0)
				}
			}
			mut count := u32(0)
			for b in 0 .. nb {
				count += u32(C.vgc_popcount8(unsafe { span.perm_bits[b] }))
			}
			if count > span.nelems {
				count = span.nelems
			}
			nsp++
			nbytes_total += u64(count) * u64(span.elem_size)
			if lo == 0 || span.base < lo {
				lo = span.base
			}
			end := span.base + usize(span.npages) * vgc_page_size
			if end > hi {
				hi = end
			}
		}
		vgc_perm_lo = lo
		vgc_perm_hi = hi
		// the card table over the range, before the length that opens the gate
		if hi > lo {
			ncards := (hi - lo) / vgc_page_size + 1
			if ncards > vgc_perm_cards_n || vgc_perm_cards == unsafe { nil } {
				vgc_perm_cards = unsafe { &u8(C.vgc_os_alloc(ncards)) }
				vgc_perm_cards_n = if vgc_perm_cards != unsafe { nil } { ncards } else { 0 }
			}
			if vgc_perm_cards != unsafe { nil } {
				unsafe { C.memset(vgc_perm_cards, 0, ncards) }
			}
		}
		vgc_perm_len = if vgc_perm_cards != unsafe { nil } { hi - lo } else { 0 }
		vgc_wb_lo = vgc_perm_lo
		vgc_wb_len = vgc_perm_len
		// the page bitmap over the range (a promotion that widened the range
		// takes a fresh one; the old is left to the OS at exit — promotions are
		// one or two per process)
		if hi > lo {
			npg := (hi - lo + vgc_page_size - 1) / vgc_page_size
			nwords := (npg + 63) / 64
			if nwords > vgc_perm_pages_n || vgc_perm_pages == unsafe { nil } {
				vgc_perm_pages = unsafe { &u64(C.vgc_os_alloc(nwords * 8)) }
				vgc_perm_pages_n = if vgc_perm_pages != unsafe { nil } { nwords } else { 0 }
			}
			if vgc_perm_pages != unsafe { nil } {
				unsafe { C.memset(vgc_perm_pages, 0, nwords * 8) }
				for i in 0 .. vgc_heap.nspans {
					span := unsafe { vgc_heap.allspans[i] }
					if span == unsafe { nil } || !span.in_use || span.perm == 0 {
						continue
					}
					p0 := (span.base - lo) / vgc_page_size
					for k in 0 .. usize(span.npages) {
						pg := p0 + k
						if pg < npg {
							unsafe {
								vgc_perm_pages[pg / 64] |= u64(1) << (pg % 64)
							}
						}
					}
				}
			}
		}
		vgc_perm_spans = nsp
		vgc_perm_bytes = nbytes_total
		vgc_perm_promoted_cycle = vgc_heap.gc_cycle
		vgc_perm_request = false
		vgc_perm_on = 1
		vgc_perm_cand_drop()
	}
}

// -d vgc_cm_verify: under the termination stop, after the concurrent mark's
// final drain, the heap is marked again from scratch — exactly the STW
// collector's mark — and every object that mark reaches but the concurrent
// one did not is a missed pointer: a store the barrier did not cover. Reports
// 0x1910 (the count) and 0x1911/0x1912 (the first eight objects' address and
// element size); the union of both marks stays, so the run remains sound.
fn vgc_cm_verify(self_idx int) {
	$if vgc_cm_verify ? {
		nsp := vgc_heap.nspans
		side := &u8(C.vgc_os_alloc(usize(nsp) * 136))
		if side == unsafe { nil } {
			return
		}
		for i in 0 .. nsp {
			span := unsafe { vgc_heap.allspans[i] }
			if span == unsafe { nil } || !span.in_use || span.mark_bits == unsafe { nil } {
				continue
			}
			unsafe { C.memcpy(voidptr(usize(side) + usize(i) * 136), span.mark_bits, (span.nelems + 7) / 8) }
		}
		// cx-home/v#15: from zero — the permanent objects are traced too, so a
		// pointer stored into one that no barrier dirtied shows as a miss
		vgc_perm_clear_zero = true
		vgc_walk_run(vgc_pool_phase_clear)
		vgc_perm_clear_zero = false
		saved_n := vgc_mark_nworkers_cur
		vgc_mark_nworkers_cur = 1
		vgc_cm_roots(self_idx)
		vgc_drain_mark_work(0)
		vgc_mark_nworkers_cur = saved_n
		mut missed := u64(0)
		for i in 0 .. nsp {
			span := unsafe { vgc_heap.allspans[i] }
			if span == unsafe { nil } || !span.in_use || span.mark_bits == unsafe { nil } {
				continue
			}
			nbytes := (span.nelems + 7) / 8
			for b in 0 .. nbytes {
				old := unsafe { *(&u8(voidptr(usize(side) + usize(i) * 136 + usize(b)))) }
				full := unsafe { span.mark_bits[b] }
				miss := full & ~old
				if miss != 0 {
					for bit in 0 .. 8 {
						if (miss & (u8(1) << u32(bit))) != 0 {
							if missed < 8 {
								C.vgc_say(0x1911, u64(span.base + usize(u32(b) * 8 + u32(bit)) * usize(span.elem_size)))
								C.vgc_say(0x1912, u64(span.elem_size))
							}
							missed++
						}
					}
				}
				// the union: what the concurrent mark marked stays marked
				unsafe {
					span.mark_bits[b] = full | old
				}
			}
		}
		if missed != 0 {
			C.vgc_say(0x1910, missed)
			vgc_cm_verify_missed += missed
		}
		C.vgc_os_free(side, usize(nsp) * 136)
	}
}

// The concurrent-mark cycle. Entered via the vgc_run_gc_spilled trampoline
// (like vgc_gc_start), so THIS thread's stack range + spilled registers are
// already recorded; the collector stays in here across the middle, so that
// range still covers the triggering mutator's frames at termination (do NOT
// refresh self).
@[markused]
fn vgc_gc_start_concurrent() {
	mut expected := vgc_phase_off
	if !C.vgc_atomic_cas_u32(&vgc_heap.gc_phase, &expected, vgc_phase_mark) {
		return
	}
	vgc_gc_owner = C.vgc_get_cache_idx()
	vgc_cm_this_cycle = true
	vgc_gc_t0 = C.vgc_now_ns() // the pacer's cycle cost (#71): the whole cycle, middle included
	vgc_gc_cpu_t0 = C.vgc_thread_cpu_ns() // cx-home/v#42: the cost in CPU time
	vgc_gc_wait_cpu = 0
	vgc_mark_nworkers_cur = vgc_mark_plan()
	vgc_walk_nworkers_cur = vgc_walk_plan()
	vgc_rescan_nworkers_cur = vgc_rescan_plan() // cx-home/v#52
	self_idx := C.vgc_get_cache_idx()
	C.vgc_trace(5, self_idx, u64(vgc_heap.gc_cycle), u64(vgc_heap.ncaches)) // GC_BEG

	// ===== STOP 1: the snapshot of the roots =====
	vgc_stw_stop(self_idx)
	vgc_ph[0] = C.vgc_now_ns()
	// cut 1: this cycle's births start at zero (every thread is stopped: its
	// born_delta is reset here, not by it), and the middle's bound is a share
	// of the last live set
	C.vgc_atomic_store_u64(&vgc_cm_born, 0)
	C.vgc_atomic_store_u32(&vgc_cm_cut, 0)
	for ci in 0 .. vgc_heap.ncaches {
		unsafe {
			vgc_cache(ci).born_delta = 0
		}
	}
	vgc_cm_born_bound = 0
	if vgc_cm_born_pct > 0 {
		vgc_cm_born_bound = C.vgc_atomic_load_u64(&vgc_heap.heap_marked) * vgc_cm_born_pct / 100
		if vgc_cm_born_bound < vgc_cm_born_min {
			vgc_cm_born_bound = vgc_cm_born_min
		}
	}
	vgc_clear_mark_bits()
	vgc_ph[1] = C.vgc_now_ns()
	// The barrier and alloc-gray are live BEFORE the roots are taken and
	// before any mutator runs again: gc_phase is already vgc_phase_mark (the
	// CAS above), which vgc_alloc_black_hook tests; wb_enabled gates the barrier.
	vgc_wb_set(1)
	vgc_scan_suspended_roots(self_idx)
	vgc_ph[2] = C.vgc_now_ns()
	vgc_mark_roots() // sets vgc_ph[3], vgc_ph[4]
	vgc_root_last_ns = vgc_ph[4] - vgc_ph[1]
	for i in 0 .. vgc_nspawn_roots {
		vgc_shade_spawn_root(usize(unsafe { vgc_spawn_roots[i] }))
	}
	// cx-home/v#15: the permanent spans written since the last cycle
	if vgc_perm_on != 0 {
		t_rescan1 := C.vgc_now_ns()
		vgc_rescan_dirty_spans(false)
		vgc_perm_rescan_ns = C.vgc_now_ns() - t_rescan1
	}
	t_resume1 := C.vgc_now_ns()
	vgc_cm_stop1_ns = t_resume1 - vgc_gc_t0
	vgc_stw_resume(self_idx)

	// ===== MIDDLE: the world runs, the markers trace =====
	mcpu0, mwait0 := vgc_mark_cpu_begin()
	vgc_cm_drain()
	mcpu1 := C.vgc_thread_cpu_ns()
	mwait1 := vgc_gc_wait_cpu
	t_stop2 := C.vgc_now_ns()
	vgc_cm_middle_ns = t_stop2 - t_resume1

	// ===== STOP 2: termination =====
	vgc_stw_stop(self_idx)
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_mark_term)
	// cut 1: the middle's births (every thread is stopped: the deltas are
	// final), and whether they throttled the allocators; the flag is down
	// before the resume
	vgc_cm_cut_last = C.vgc_atomic_load_u32(&vgc_cm_cut) != 0
	C.vgc_atomic_store_u32(&vgc_cm_cut, 0)
	vgc_cm_born_bound = 0
	mut born := C.vgc_atomic_load_u64(&vgc_cm_born)
	for ci in 0 .. vgc_heap.ncaches {
		unsafe {
			born += vgc_cache(ci).born_delta
			vgc_cache(ci).born_delta = 0
		}
	}
	vgc_cm_born_last = born
	vgc_cm_roots(self_idx)
	t_rescan := C.vgc_now_ns()
	rcpu0, _ := vgc_mark_cpu_begin()
	vgc_rescan_dirty_spans(true)
	vgc_cm_rescan_ns = C.vgc_now_ns() - t_rescan
	vgc_rescan_last_work_ns = vgc_cm_rescan_ns * u64(vgc_rescan_nworkers_cur)
	// cx-home/v#55: a serial re-scan's work is its CPU time when the box
	// stretched its wall (vgc_mark_work_from_cpu)
	if rcpu0 != 0 && vgc_rescan_nworkers_cur <= 1 {
		rcpu1 := C.vgc_thread_cpu_ns()
		if rcpu1 > rcpu0 && rcpu1 - rcpu0 < vgc_rescan_last_work_ns {
			vgc_rescan_last_work_ns = rcpu1 - rcpu0
		}
	}
	vgc_cm_drain()
	vgc_cm_verify(self_idx)
	vgc_ph[5] = C.vgc_now_ns()
	// the next cycle's marker plan sees the middle's wall as the mark (the
	// pool's share of it as work), as the STW collector does for its mark
	vgc_mark_last_ns = vgc_cm_middle_ns
	vgc_mark_last_work_ns = vgc_mark_last_ns * u64(if vgc_mark_nworkers_cur > 1 {
		vgc_mark_nworkers_cur
	} else {
		1
	})
	vgc_mark_work_from_cpu_at(mcpu0, mwait0, mcpu1, mwait1)
	vgc_wb_set(vgc_perm_on * 2) // cx-home/v#15: the permanent regime stays

	marked := vgc_count_marked()
	vgc_ph[6] = C.vgc_now_ns()
	vgc_mark_adapt(marked)
	vgc_grow_gate_prev_marked = C.vgc_atomic_load_u64(&vgc_heap.heap_marked)
	// cut 1: the count read every bit the alloc-black hook set — the middle's
	// births, alive or already dead, which this cycle could not judge. The
	// pacer's live set (heap_marked, the goal's base and the trace's marked=)
	// is the count less the births; heap_live keeps the whole count, so the
	// births stand as allocation since this cycle and the next one judges them.
	mut net := marked
	if born < net {
		net -= born
	} else {
		net = 0
	}
	C.vgc_atomic_store_u64(&vgc_heap.heap_marked, net)
	for ci in 0 .. vgc_heap.ncaches {
		unsafe {
			vgc_heap.total_alloc += vgc_cache(ci).alloc_delta
			vgc_cache(ci).alloc_delta = 0
			vgc_cache(ci).live_delta = 0
		}
	}
	C.vgc_atomic_store_u64(&vgc_heap.heap_live, marked)

	// Sweep, stopped: no span is freed during the middle, so this is the STW
	// collector's sweep. vgc_protect_cached_spans first, as there (a span a
	// thread still allocates from is not an orphan).
	vgc_heap.sweep_gen++
	C.vgc_atomic_store_u32(&vgc_heap.sweep_done, 0)
	vgc_heap.sweep_idx = 0
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_sweep)
	vgc_protect_cached_spans()
	C.vgc_trace(9, self_idx, u64(vgc_heap.gc_cycle), 0) // SWEEP0
	vgc_do_sweep()
	vgc_ph[7] = C.vgc_now_ns()
	vgc_walk_adapt((vgc_ph[1] - vgc_ph[0]) + (vgc_ph[6] - vgc_ph[5]) + vgc_ph_swalk_ns)
	C.vgc_trace(10, self_idx, u64(vgc_heap.gc_cycle), 0) // SWEEP1
	vgc_fixup_caches()
	// The cycle and the trigger advance while the world is STILL stopped (see
	// vgc_gc_start's note: a mutator resumed before the bump stamps a span it
	// acquires with the old cycle). The trace line's pause is the two stops.
	vgc_update_trigger()
	vgc_cm_stop2_ns = vgc_gc_last_end - t_stop2
	vgc_cm_pause_ns = vgc_cm_stop1_ns + vgc_cm_stop2_ns
	// the feedback (vgc_cm_backoff): this cycle's stops against the last
	// stop-the-world pause
	if vgc_cm_mode == 2 && vgc_stw_last_pause_ns > 0 {
		// at least half the pause must be bought: the middle costs the mutators
		// the markers' cores and the allocation that runs through it (RSS)
		// (cut 1: a middle whose births throttled the allocators is judged
		// by its stops like any other — the bound is what the probe may cost
		// in floating garbage, the netting takes the rest)
		if vgc_cm_pause_ns * 2 >= vgc_stw_last_pause_ns {
			vgc_cm_backoff = vgc_cm_backoff_len
			if vgc_cm_backoff_len < 64 {
				vgc_cm_backoff_len *= 2
			}
		} else {
			vgc_cm_backoff_len = 8
		}
	}
	vgc_gctrace_emit()
	vgc_heap.gc_cycle++
	vgc_heap.total_alloc_at_gc = C.vgc_atomic_load_u64(&vgc_heap.total_alloc)
	vgc_stw_resume(self_idx)
	C.vgc_trace(12, self_idx, u64(vgc_heap.gc_cycle), 0) // GC_END
	vgc_gc_owner = -1
	vgc_rescan_nworkers_cur = 1 // the stop-the-world collector's re-scan is serial
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_off)
}

// vgc_gctrace_emit writes the VGC_GCTRACE=1 per-cycle pacing line (GODEBUG=gctrace
// analog) for the cycle about to be counted. Both collectors call it under STW right
// after the trigger recompute and before gc_cycle advances, so every field is a
// consistent snapshot: cycle, marked (true live set), the recomputed base goal (pre
// thread-multiplier), arena/span pressure, live mutators. Env-gated (one integer
// test per cycle when off).
@[markused]
fn vgc_gctrace_emit() {
	if vgc_gctrace == 0 {
		return
	}
	mut pause_us := u64(0)
	if vgc_gc_last_end > vgc_gc_t0 {
		pause_us = (vgc_gc_last_end - vgc_gc_t0) / 1000
	}
	$if vgc_concurrent ? {
		// cx-private#1910: a concurrent cycle's pause is its two stops (the
		// middle ran beside the mutators); a stop-the-world cycle's is the cycle
		if vgc_cm_this_cycle {
			pause_us = vgc_cm_pause_ns / 1000
		}
	}
	C.vgc_gctrace_line(u64(vgc_heap.gc_cycle), C.vgc_atomic_load_u64(&vgc_heap.heap_marked),
		C.vgc_atomic_load_u64(&vgc_heap.next_gc), u64(vgc_heap.narenas), u64(vgc_heap.nspans),
		u64(C.vgc_atomic_load_u32(&vgc_heap.live_threads)), vgc_headroom / 1024, pause_us,
		vgc_heap.pool_bytes / 1024, vgc_heap.pool_trimmed_bytes / 1024, vgc_idle_defrag_merged_kb)
	if vgc_gctrace >= 2 {
		// cx-home/v#15: where the pause went (us per phase), the data-segment
		// bytes the root scan walked and the spans the clear/sweep walks visited.
		mut seg := u64(0)
		for k in 0 .. vgc_nseg {
			if vgc_seg_hi[k] > vgc_seg_lo[k] {
				seg += u64(vgc_seg_hi[k] - vgc_seg_lo[k])
			}
		}
		mut in_use := u64(0)
		for w in 0 .. (vgc_heap.nspans + 7) / 8 {
			in_use += u64(C.vgc_popcount8(unsafe { vgc_heap.inuse_bits[w] }))
		}
		C.vgc_gctrace_phases(u64(vgc_heap.gc_cycle), vgc_ph_us(vgc_gc_t0, vgc_ph[0]), vgc_ph_us(vgc_ph[0],
			vgc_ph[1]), vgc_ph_us(vgc_ph[1], vgc_ph[2]), vgc_ph_us(vgc_ph[2], vgc_ph[3]), vgc_ph_us(vgc_ph[3],
			vgc_ph[4]), vgc_ph_us(vgc_ph[4], vgc_ph[5]), vgc_ph_us(vgc_ph[5], vgc_ph[6]), vgc_ph_us(vgc_ph[6],
			vgc_ph[7]), vgc_ph_us(vgc_ph[7], vgc_gc_last_end), seg / 1024, in_use,
			u64(vgc_mark_nworkers_cur), u64(vgc_walk_nworkers_cur), vgc_ph_swalk_ns / 1000,
			vgc_ph_sapply_ns / 1000)
		$if vgc_concurrent ? {
			// cx-home/v#15: the permanent generation's share of the cycle
			if vgc_perm_on != 0 {
				C.vgc_gctrace_perm(u64(vgc_heap.gc_cycle), vgc_perm_spans, vgc_perm_bytes / 1024,
					vgc_cm_rescan_spans, vgc_cm_rescan_objs, vgc_perm_young_objs, vgc_perm_rescan_ns / 1000,
					vgc_cm_verify_missed, u64(if vgc_perm_promoted_cycle == vgc_heap.gc_cycle { 1 } else { 0 }))
			}
			// cx-private#1910: the concurrent cycle's shape — the two stops, the
			// middle, the termination re-scan's spans/objects and time
			if vgc_cm_this_cycle {
				C.vgc_gctrace_cm(u64(vgc_heap.gc_cycle), vgc_cm_stop1_ns / 1000, vgc_cm_middle_ns / 1000,
				vgc_cm_stop2_ns / 1000, vgc_cm_rescan_ns / 1000, vgc_cm_rescan_spans, vgc_cm_rescan_objs,
					vgc_cm_verify_missed, vgc_cm_born_last / 1024, u64(if vgc_cm_cut_last { 1 } else { 0 }))
			}
		}
	}
}

// Scan the roots of every suspended mutator: refresh its stack range from its
// real (suspended) SP and shade its register-resident roots. Mach
// thread_get_state yields both, so register roots come for free — closing the
// stack-only-scan gap that dropped live values. (stw_root_scan.c prototype.)
fn vgc_scan_suspended_roots(self_idx int) {
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { vgc_cache(i) }
		if !c.registered || i == self_idx || c.mach_port == 0 {
			continue
		}
		$if !vgc_legacy_stw ? {
			// Cooperative parkers (stopped==1 AND parked for THIS cycle) already
			// recorded their SELF-SPILLED range via vgc_park_spill; calling
			// thread_get_state on a spinning parker would overwrite stack_lo/hi
			// with the spin-loop range and drop its roots. A stale park (previous
			// cycle's seq) means the thread was signal-suspended above — its range
			// MUST be refreshed externally (the stale self-recorded one no longer
			// covers its current frames).
			if C.vgc_atomic_load_u32(&vgc_cache(i).stopped) != 0
				&& c.park_seq == C.vgc_atomic_load_u32(&vgc_heap.gc_stop_seq) {
				continue
			}
			// cx #316: a safe-region thread (per the suspend loop's snapshot — NOT a
			// live re-read: the thread may since have stored safe=0 and be spinning
			// in its exit handshake, and thread_get_state on a spinning, unsuspended
			// thread yields racy garbage) keeps its self-recorded entry-time range;
			// shade its off-stack callee-saved snapshot here — the stack scan cannot
			// see it (the enter frame died and the blocking call reused its
			// addresses; that is exactly why the spill is off-stack).
			if c.cov_safe {
				for k in 0 .. vgc_safe_spill_words {
					vgc_shade(unsafe { vgc_cache(i).safe_regs[k] }, 0)
				}
				continue
			}
		}
		mut sp := usize(0)
		// 31 GP (x0–x28 + fp + lr) + 64 NEON lanes (v0–v31 × 2) = 95 conservative
		// root candidates per suspended thread (arm64; x86_64 fills only the first 15).
		mut regs := [95]usize{}
		n := C.vgc_thread_regs(i, &sp, &regs[0], 95)
		C.vgc_trace(8, i, u64(sp), u64(n)) // SCAN (sp + reg count actually captured)
		if n > 0 && sp != 0 {
			vgc_refresh_stack_range_for_sp(i, sp) // [sp, stack_base]
			for k in 0 .. n {
				vgc_shade(regs[k], 0) // register-resident roots
			}
			// DIAGNOSTIC (root-scan-miss localizer): is the watched object held
			// only in this suspended thread's registers (e.g. main spin-waiting
			// on c with c in a callee-saved reg)? Bounded to n captured regs.
			if vgc_watch_addr != 0 {
				for k in 0 .. n {
					if regs[k] == vgc_watch_addr {
						vgc_watch_in_reg = u32(i + 1)
						break
					}
				}
			}
		}
	}
}

// ============================================================
// Mark phase (translated from Go's mgcmark.go)
// ============================================================

// Clear all mark bits before a new GC cycle
fn vgc_clear_mark_bits() {
	// Cycle start, under STW with vgc_heap.lock held (both the STW and concurrent
	// collectors route through here once per cycle): promote descriptors retired
	// by LAST cycle's pool coalescing to the reusable list — the one-cycle grace
	// that keeps a retired descriptor's identity stable across any mutator frozen
	// mid-vgc_free at the previous STW (cx #360, see span_meta_pending).
	vgc_span_meta_promote_pending()
	vgc_walk_run(vgc_pool_phase_clear) // cx-home/v#16: on the pool when the table is large
}

// cx-home/v#16: one walker's share of the clear. Chunks of vgc_walk_chunk
// inuse_bits words are claimed from vgc_walk_cursor until the table is done;
// with one walker (n == 1) that is the whole table in order.
fn vgc_walk_clear(w int, n int) {
	nb := u32((vgc_heap.nspans + 7) / 8)
	for {
		w1 := C.vgc_atomic_add_u32(&vgc_walk_cursor, vgc_walk_chunk)
		w0 := w1 - vgc_walk_chunk
		if w0 >= nb {
			return
		}
		hi := if w1 < nb { w1 } else { nb }
		for wi in w0 .. hi {
			mut bits := unsafe { vgc_heap.inuse_bits[int(wi)] }
			for bits != 0 {
				bi := C.vgc_ctz8(bits)
				bits &= bits - 1
				span := unsafe { vgc_heap.allspans[int(wi) * 8 + bi] }
				if span == unsafe { nil } || !span.in_use {
					continue
				}
				if span.mark_bits != unsafe { nil } {
					bitmap_size := (span.nelems + 7) / 8
					// cx-home/v#15: a permanent span's objects start the cycle
					// marked (the verifier's full re-mark starts from zero)
					if span.perm != 0 && span.perm_bits != unsafe { nil } && !vgc_perm_clear_zero {
						unsafe { C.memcpy(span.mark_bits, span.perm_bits, bitmap_size) }
					} else {
						unsafe { C.memset(span.mark_bits, 0, bitmap_size) }
					}
				}
			}
		}
	}
}

// One walker's share of the count: marked bytes into its own stride of
// vgc_walk_sum (the collector sums the strides after the join).
fn vgc_walk_count(w int, n int) {
	nb := u32((vgc_heap.nspans + 7) / 8)
	mut total := u64(0)
	for {
		w1 := C.vgc_atomic_add_u32(&vgc_walk_cursor, vgc_walk_chunk)
		w0 := w1 - vgc_walk_chunk
		if w0 >= nb {
			break
		}
		hi := if w1 < nb { w1 } else { nb }
		for wi in w0 .. hi {
			mut bits := unsafe { vgc_heap.inuse_bits[int(wi)] }
			for bits != 0 {
				bi := C.vgc_ctz8(bits)
				bits &= bits - 1
				span := unsafe { vgc_heap.allspans[int(wi) * 8 + bi] }
				if span == unsafe { nil } || !span.in_use || span.mark_bits == unsafe { nil } {
					continue
				}
				nbytes := (span.nelems + 7) / 8
				mut count := u32(0)
				for b in 0 .. nbytes {
					count += u32(C.vgc_popcount8(unsafe { span.mark_bits[b] }))
				}
				// Clamp to nelems (last byte may have extra bits)
				if count > span.nelems {
					count = span.nelems
				}
				total += u64(count) * u64(span.elem_size)
			}
		}
	}
	vgc_walk_sum[w * 16] = total
}

// One walker's share of the sweep: the per-span bit work, and the span's
// verdict into vgc_walk_tag[slot]. No list is touched here (the RULE at
// vgc_walk_chunk); vgc_walk_sweep_apply applies the verdicts after the join.
fn vgc_walk_sweep(w int, n int) {
	nb := u32((vgc_heap.nspans + 7) / 8)
	tags := unsafe { &u8(voidptr(vgc_walk_tag)) }
	for {
		w1 := C.vgc_atomic_add_u32(&vgc_walk_cursor, vgc_walk_chunk)
		w0 := w1 - vgc_walk_chunk
		if w0 >= nb {
			return
		}
		hi := if w1 < nb { w1 } else { nb }
		for wi in w0 .. hi {
			mut bits := unsafe { vgc_heap.inuse_bits[int(wi)] }
			for bits != 0 {
				bi := C.vgc_ctz8(bits)
				bits &= bits - 1
				idx := int(wi) * 8 + bi
				span := unsafe { vgc_heap.allspans[idx] }
				if span == unsafe { nil } || !span.in_use {
					continue
				}
				tag := vgc_sweep_span_bits(span)
				if tag != vgc_walk_tag_none {
					unsafe {
						tags[idx] = tag
					}
				}
			}
		}
	}
}

// The sweep's serial tail: the verdicts in slot order — the order the serial
// sweep visited the spans — so the pool and the central lists end the cycle
// exactly as a one-thread sweep leaves them. Clears each tag as it goes.
fn vgc_walk_sweep_apply() {
	tags := unsafe { &u8(voidptr(vgc_walk_tag)) }
	for idx in 0 .. vgc_heap.nspans {
		t := unsafe { tags[idx] }
		if t == vgc_walk_tag_none {
			continue
		}
		unsafe {
			tags[idx] = vgc_walk_tag_none
		}
		span := unsafe { vgc_heap.allspans[idx] }
		if span == unsafe { nil } || !span.in_use {
			continue
		}
		vgc_sweep_span_apply(span, t)
	}
}

// Run one walk phase: alone when this cycle has one walker (or no pool
// thread exists), else on the pool with the collector as walker 0, joined
// before this returns.
fn vgc_walk_run(phase u32) {
	C.vgc_atomic_store_u32(&vgc_walk_cursor, 0)
	n := vgc_walk_nworkers_cur
	if n <= 1 || vgc_mark_pool_n == 0 {
		vgc_pool_phase_run(phase, 0, 1)
		return
	}
	vgc_pool_run(phase, n)
}

// Conservative root scanning: scan thread stacks and look for pointers into the heap.
// Translated from Go's markroot() / scanblock() - but using conservative scanning
// since V compiles to C and we don't have precise type info at runtime.
fn C.vgc_data_segments(los &usize, his &usize, max_ranges int) int

// vgc_protect_cached_spans stamps every mcache-RESIDENT span's sweep_gen with the
// current gc_cycle so THIS cycle's sweep skips it (residual #4 fix). A span cached in
// a thread's mcache (caches[i].alloc[sc], on_central==0) is referenced only by that
// cache slot AND, for a thread suspended mid-allocation, by a local register/stack
// pointer. A span DESCRIPTOR is vgc_os_alloc'd OUTSIDE the GC arena, so the
// conservative root scan never protects it. An empty (alloc_count==0) cached span
// would otherwise be reclaimed by vgc_sweep_span — the on_central==0 path skips the
// central unlink and calls vgc_put_free_span, which resets nelems/elem_size=0 and pools
// it on free_spans — while it is still in the mcache / held in a suspended owner's
// local. The owner resumes and reads a zeroed-or-torn span (nelems=0) ->
// vgc_span_alloc_obj nil -> vgc_malloc NULL -> caller null-deref (the residual
// concurrent-HTTP segv; register/niltrace-confirmed: nelems=0, in_use=1, on_central=0).
// vgc_fixup_caches nulls the recycled CACHE SLOT post-sweep but cannot fix a local
// pointer held by a thread frozen inside vgc_malloc. Reusing the existing in-flight
// sweep_gen guard is the fix. Excludes exited threads (registered=false) so their spans
// still reclaim, and a span evicted to central (on_central!=0) is no longer reachable
// here so it reclaims next cycle. MUST run under STW, after mark, before sweep, while
// gc_cycle still holds this cycle's value.
fn vgc_protect_cached_spans() {
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { vgc_cache(i) }
		if !c.registered {
			continue
		}
		for sc in 0 .. 136 {
			s := unsafe { c.alloc[sc] }
			if s != unsafe { nil } {
				unsafe {
					s.sweep_gen = u32(vgc_heap.gc_cycle)
				}
			}
		}
		// #58: protect the TINY-cursor block's owning span too. Once the tiny
		// block's span fills, it is evicted from c.alloc[] to central and the loop
		// above no longer reaches it — yet the cursor still carves from it. The
		// block itself is conservatively rooted (the caches array lives inside the
		// vgc_heap global, which mark_roots scans as a data segment), so it is
		// marked and its span non-empty; this stamp is belt-and-braces against
		// alloc_count drift ever making that span look empty to the recycler.
		if c.tiny != 0 {
			ts := vgc_find_span(voidptr(c.tiny))
			if ts != unsafe { nil } {
				unsafe {
					(&VGC_Span(ts)).sweep_gen = u32(vgc_heap.gc_cycle)
				}
			}
		}
	}
}

// vgc_fixup_caches clears every per-thread mcache slot whose cached span was
// recycled by THIS cycle's sweep (the tiny-allocator cursor is KEPT — see the #58
// note inside; dropping it raced signal-frozen mutators mid-carve). The collector
// sweeps ALL spans, including the one a thread currently has cached in
// caches[i].alloc[class]; if sweep finds that span empty it recycles it to the
// free-span pool (in_use=false, bitmaps freed, pages decommitted) while the mcache
// still points at it. Left alone, that stale pointer (a) makes the next alloc
// sub-allocate into freed/decommitted memory, and (b) breaks span reuse —
// vgc_cache_get_span sees alloc_count(0) < nelems(0) == false, mis-treats the pooled
// span as "full", and the allocator creates fresh spans despite a full pool ->
// unbounded arena growth. Nulling the slot makes the thread refill cleanly from
// central / the pool after resume. Spans that survived sweep (still in_use) stay
// cached. MUST be called after vgc_do_sweep and before the world is resumed; it only
// reads span.in_use and writes mcache fields (no central-list surgery -> no
// double-membership, no span-init race).
fn vgc_fixup_caches() {
	for i in 0 .. vgc_heap.ncaches {
		mut c := unsafe { vgc_cache(i) }
		// #58 ROOT CAUSE (workers8 string_clone segfault, lldb-captured): the tiny
		// cursor was UNCONDITIONALLY dropped here. But a mutator can be SIGNAL-
		// FROZEN (darwin/linux async-suspend STW stops threads at arbitrary PCs)
		// inside vgc_malloc_noscan_opts BETWEEN its `cache.tiny != 0` check and the
		// `cache.tiny + off` carve. Zeroing the cursor under it made the resumed
		// thread compute ptr = 0 + off (near-NULL) and hand THAT out as a live
		// buffer -> immediate SIGSEGV on the first write (captured: res.str = 0x8
		// with a healthy 2-byte source key). The drop is also UNNECESSARY: the tiny
		// block is conservatively ROOTED (this caches array lives inside the
		// vgc_heap global, which mark_roots scans as a data segment), so it is
		// marked, survives sweep, and vgc_protect_cached_spans stamps its owning
		// span against recycle. Keep the cursor; drop it ONLY if its span was
		// genuinely recycled this cycle — which the protections above make
		// impossible, so say it LOUDLY if it ever fires.
		if c.tiny != 0 {
			ts := vgc_find_span(voidptr(c.tiny))
			if ts == unsafe { nil } || !ts.in_use {
				C.vgc_say(0x717e, u64(c.tiny)) // TINY cursor span recycled — protection hole
				c.tiny = 0
				c.tiny_offset = 0
			}
		}
		for sc in 0 .. 136 {
			span := unsafe { c.alloc[sc] }
			if span != unsafe { nil } && !span.in_use {
				unsafe {
					c.alloc[sc] = nil
				}
			}
		}
	}
}

fn vgc_mark_roots() {
	// Scan the global / BSS data segments (V __global roots). Without this, an
	// object reachable only through a global (e.g. rand.default_rng) is reclaimed,
	// and a later access — typically a module's at-exit _deinit — dereferences
	// freed memory and SIGSEGVs. Conservative, like the stack scan.
	// cx #973: read the init-time cache — NEVER call into the loader from here.
	// This runs under STW, and the loader lock can be held by a mach-suspended
	// straggler (see the vgc_seg_lo doc above); acquiring it deadlocks the
	// collector. The fallback fires only if a cycle precedes vgc_init.
	if vgc_nseg == 0 {
		vgc_cache_data_segments()
	}
	nseg := vgc_nseg
	$if vgc_rootdiag ? {
		vgc_rd_begin_cycle()
		vgc_rd_cat = 1
	}
	// Scan the WHOLE data segment, including the collector's own `vgc_heap` struct.
	// It is tempting to skip vgc_heap (it is large and is "just" collector metadata),
	// but doing so intermittently reclaims live data: vgc_heap's per-thread caches
	// hold pointers (the tiny-allocator cursor / the in-flight mcache spans' object
	// memory) that conservatively root objects the stack+register scan does not fully
	// cover during thread create/exit churn. Excluding it removes that protection and
	// G-CHURN fails ~1-in-3 with reclaimed anchor nodes (verified by isolation). So
	// the caches stay scanned; the rest of vgc_heap and the collector's other
	// region-address words do NOT (vgc_scan_data_range, cx-private #1783): an
	// arena's base or a slab's end is also the address of the object carved there,
	// and scanning those words rooted it for the life of the process.
	$if vgc_verify ? {
		// DEBUG: dump the data-segment ranges once so we can check whether a given
		// __global's address is actually covered by the conservative root scan.
		if !vgc_segdump_done {
			vgc_segdump_done = true
			C.vgc_say(0x5e60, u64(nseg)) // SEG count
			for k in 0 .. nseg {
				C.vgc_say(0x5e61, u64(vgc_seg_lo[k])) // SEG lo
				C.vgc_say(0x5e62, u64(vgc_seg_hi[k])) // SEG hi
			}
		}
	}
	for k in 0 .. nseg {
		if vgc_seg_lo[k] > 0 && vgc_seg_hi[k] > vgc_seg_lo[k] {
			vgc_scan_data_range(vgc_seg_lo[k], vgc_seg_hi[k])
		}
	}
	// The per-thread cache slots, to the high-water mark only (cx-home/v#27): the
	// tiny cursor and the in-flight mcache spans are load-bearing roots during
	// thread create/exit churn (see above); the slots live in vgc_os_alloc'd
	// chunks now, outside the data segment, so they are scanned here, chunk by
	// chunk, ncaches records in all — not a fixed 1,024 x 1.5 KB array.
	$if vgc_rootdiag ? {
		vgc_rd_cat = 2
	}
	mut left := vgc_heap.ncaches
	for ci in 0 .. C.vgc_ncache_chunks() {
		if left <= 0 {
			break
		}
		n := if left < vgc_cache_chunk_slots { left } else { vgc_cache_chunk_slots }
		base := usize(C.vgc_cache_chunk(ci))
		vgc_scan_range(base, base + usize(n) * usize(sizeof(VGC_Cache)), 0)
		left -= n
	}
	// The suspend records too (the captured register files, this cycle's and
	// earlier ones'): the fixed BSS tables they replaced were scanned whole with
	// the data segment every cycle, and this keeps exactly that coverage.
	$if vgc_rootdiag ? {
		vgc_rd_cat = 3
	}
	for ci in 0 .. C.vgc_ncache_chunks() {
		mut slo := usize(0)
		mut shi := usize(0)
		if C.vgc_susp_chunk_bounds(ci, &slo, &shi) != 0 {
			vgc_scan_range(slo, shi, 0)
		}
	}
	vgc_ph[3] = C.vgc_now_ns()

	// Scan each registered thread's stack
	for i in 0 .. vgc_heap.ncaches {
		cache := unsafe { vgc_cache(i) }
		if !cache.registered {
			continue
		}
		if cache.stack_lo > 0 && cache.stack_hi > 0 && cache.stack_hi > cache.stack_lo {
			$if vgc_rootdiag ? {
				vgc_rd_cat = u32(10 + i)
				vgc_rd_base = cache.stack_hi
				vgc_rd_own = i == C.vgc_get_cache_idx()
			}
			vgc_scan_range(cache.stack_lo, cache.stack_hi, 0)
			$if vgc_rootdiag ? {
				vgc_rd_cat = 0
				vgc_rd_base = 0
				vgc_rd_own = false
			}
			// DIAGNOSTIC (root-scan-miss localizer): does THIS thread's stack hold
			// a pointer to the watched object? Bounded to the stack ranges only.
			if vgc_watch_addr != 0 {
				vgc_watch_scan_range(cache.stack_lo, cache.stack_hi, i)
			}
		}
	}

	vgc_ph[4] = C.vgc_now_ns()

	// Shade pinned objects — cgo-safe explicit roots (see vgc_pin). A live object
	// reachable only from non-GC (FFI/C) memory is invisible to the precise scan
	// above; pinning makes it a root so it (and its transitive referents) survive.
	// Lock-free read under STW: frozen mutators cannot mutate the set, and unpin's
	// publish-before-shrink keeps every live pin visible (see vgc_pin/vgc_unpin).
	np := vgc_npins
	for k in 0 .. np {
		vgc_shade(usize(unsafe { vgc_pins[k] }), 0)
	}
	$if vgc_rootdiag ? {
		vgc_rd_cat = 0
	}
}

// vgc_scan_data_range scans a data-segment range as vgc_scan_range does, minus
// the collector's own bookkeeping words: every field of vgc_heap except the
// per-thread caches, plus the vgc_arena_lo and vgc_workbuf_cur/_end globals.
// Those words hold region addresses and counters, never object references: the
// arena table holds each arena's base, span_meta_cur/_end and the workbuf
// cursor/end hold the ends of mmapped slabs, and the central and free-span lists
// hold span DESCRIPTORS (bump-slab memory outside the arenas). But a region's
// base, or the end of a slab mmapped directly below an arena, is also the
// address of the first object carved in that arena, so scanning them rooted that
// object and everything it reaches for the life of the process. The first such
// root found was the arena table: once the VGCG-1 grow gate moved one carve,
// the streaming bench's finished 24 MB result landed at the second arena's base
// and was marked in every later cycle (cx-private #1783;
// bench/parallel-alloc/vgc_arena_base_root_test.v). The second reader then found
// span_meta_end (vgc_metadata_roots_test.v). vgc_arena_hi is not excluded
// because vgc_shade already refuses addresses at or above it. The caches stay
// scanned: their tiny cursor and in-flight spans are load-bearing roots during
// thread create/exit churn (see vgc_mark_roots).
fn vgc_scan_data_range(lo usize, hi usize) {
	// cx-home/v#27: the caches no longer sit inside vgc_heap (chunks, scanned to
	// the high-water mark by vgc_mark_roots), so the whole struct is excluded.
	heap_lo := usize(voidptr(&vgc_heap))
	heap_hi := heap_lo + usize(sizeof(VGC_Heap))
	w := usize(sizeof(usize))
	// cx-home/v#15: the permanent range's bounds and the barrier gate's base are
	// span addresses too — vgc_perm_hi is the END of the highest permanent span,
	// which is the base of whatever span follows it, and vgc_perm_lo / vgc_wb_lo
	// the base of the lowest, whose first slot may hold a young object: scanned,
	// they rooted that object for the life of the process (a dropped 1.9 MB
	// array and the 7.5 MB of strings it held, permanent/perm_transient.v)
	mut ex_los := [heap_lo, usize(voidptr(&vgc_arena_lo)), usize(voidptr(&vgc_workbuf_cur)),
		usize(voidptr(&vgc_workbuf_end)), usize(voidptr(&vgc_perm_lo)), usize(voidptr(&vgc_perm_hi)),
		usize(voidptr(&vgc_wb_lo)), 0, 0, 0, 0, 0]!
	mut ex_his := [heap_hi, usize(voidptr(&vgc_arena_lo)) + w, usize(voidptr(&vgc_workbuf_cur)) + w,
		usize(voidptr(&vgc_workbuf_end)) + w, usize(voidptr(&vgc_perm_lo)) + w,
		usize(voidptr(&vgc_perm_hi)) + w, usize(voidptr(&vgc_wb_lo)) + w, 0, 0, 0, 0, 0]!
	// cx-home/v#15: the collector's own static tables (vgc_static_tables doc,
	// vgc_platform.h): the arena address maps, the chunk tables and the
	// touched-page cache — VGC_STATIC_TABLES (5) of them, from slot 7.
	C.vgc_static_tables(&ex_los[7], &ex_his[7])
	// The collector's own clocks, CPU times and bit summaries are integers, not
	// references, and nothing else stores into them: scanned, a value that falls
	// inside the arenas roots whatever it points at. vgc_gc_cpu_t0 (cx-home/v#42)
	// holds the collecting thread's CPU time in ns, ~4.3-8.6e9 after 4-8 s of
	// work = 0x1_0000_0000-0x2_0000_0000, where the macOS arenas sit: on the
	// streaming bench (code_streaming_throughput_bench) it held an interior
	// address of a dead 100 MiB corpus copy at gc 43, so that cycle marked
	// 200 MB for 100, the goal went to 600 MB three cycles later and a seventh
	// arena was carved: peak RSS 513 -> 613 MB, the loop's perf-pair red on
	// ffc9f039f (VGC_ROOTDIAG named the word; cx-home/v#45). Monotonic ns since boot (a CI
	// VM minutes old: 1e11-1e12) and the pool's bit summaries alias the same way.
	// cx-home/v#15 lever 5: the #58 scanned-window shadow (vgc_spchk_*, 32 KB):
	// stack bounds, cycle numbers and parked flags, written only under
	// -d vgc_spcheck, never a reference.
	spchk_len := usize(vgc_spchk_slots) * w
	own_los := [usize(voidptr(&vgc_spchk_lo[0])), usize(voidptr(&vgc_spchk_hi[0])), usize(voidptr(&vgc_spchk_cyc[0])), usize(voidptr(&vgc_spchk_parked[0])), usize(voidptr(&vgc_ph[0])), usize(voidptr(&vgc_walk_sum[0])), usize(voidptr(&vgc_pool_hot_bits[0])), usize(voidptr(&vgc_pool_cold_bits[0])), usize(voidptr(&vgc_gc_t0)), usize(voidptr(&vgc_gc_last_end)), usize(voidptr(&vgc_gc_cpu_t0)), usize(voidptr(&vgc_gc_wait_cpu)), usize(voidptr(&vgc_gate_last_pause)), usize(voidptr(&vgc_gate_last_interval)), usize(voidptr(&vgc_stw_last_pause_ns)), usize(voidptr(&vgc_perm_rescan_ns)), usize(voidptr(&vgc_root_last_ns)), usize(voidptr(&vgc_mark_last_ns)), usize(voidptr(&vgc_mark_last_work_ns)), usize(voidptr(&vgc_ph_swalk_ns)), usize(voidptr(&vgc_ph_sapply_ns)), usize(voidptr(&vgc_envchk_last)), usize(voidptr(&vgc_cm_pause_ns)), usize(voidptr(&vgc_cm_stop1_ns)), usize(voidptr(&vgc_cm_middle_ns)), usize(voidptr(&vgc_cm_stop2_ns)), usize(voidptr(&vgc_cm_rescan_ns))]!
	own_lens := [spchk_len, spchk_len, spchk_len, spchk_len, usize(8) * w, usize(vgc_walk_sum_len) * w, usize(129) * w, usize(129) * w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w, w]!
	mut cur := lo
	for cur < hi {
		// the excluded range that starts first among those ending past cur
		mut ex_lo := hi
		mut ex_hi := hi
		for k in 0 .. ex_los.len {
			if ex_his[k] > cur && ex_los[k] < ex_lo {
				ex_lo = ex_los[k]
				ex_hi = ex_his[k]
			}
		}
		for k in 0 .. own_los.len {
			if own_los[k] + own_lens[k] > cur && own_los[k] < ex_lo {
				ex_lo = own_los[k]
				ex_hi = own_los[k] + own_lens[k]
			}
		}
		if ex_lo > cur {
			vgc_scan_touched(cur, if ex_lo < hi { ex_lo } else { hi })
		}
		if ex_hi <= cur {
			break
		}
		cur = ex_hi
	}
}

// vgc_scan_touched scans the pages of a data-segment range the process has
// touched since exec (cx-home/v#15; vgc_touched_ranges doc, vgc_platform.h): a
// never-written zero-fill page holds no reference, and reading it faulted a
// zeroed page in, so the scan kept the whole data segment resident and spent
// about half its time on zero pages. Off darwin (or on any mincore failure)
// the range is scanned whole, as before.
fn vgc_scan_touched(lo usize, hi usize) {
	mut los := [usize(0), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0]!
	mut his := [usize(0), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0]!
	n := C.vgc_touched_ranges(lo, hi, &los[0], &his[0], 32)
	for k in 0 .. n {
		vgc_scan_range(los[k], his[k], 0)
	}
}

// Scan a memory range conservatively, looking for pointers into the GC heap.
// Each word-aligned value that looks like a heap pointer is treated as a root.
// Translated from Go's scanblock() with conservative pointer finding.
// `w` is the marker's slot (0 = the collector; cx-home/v#16): the work buffer
// a newly greyed object is pushed to.
fn vgc_scan_range(lo usize, hi usize, w int) {
	// Align to word boundaries
	start := (lo + sizeof(usize) - 1) & ~(usize(sizeof(usize)) - 1)
	mut addr := start
	for addr + sizeof(usize) <= hi {
		val := unsafe { *(&usize(voidptr(addr))) }
		if val != 0 {
			$if vgc_rootdiag ? {
				if vgc_rd_cat != 0 {
					vgc_rd_shade_root(addr, val, w)
				} else {
					vgc_shade(val, w)
				}
			} $else {
				vgc_shade(val, w)
			}
		}
		addr += sizeof(usize)
	}
}

// Shade marks an object grey (discovered but not yet scanned).
// Translated from Go's shade() in mgcmark.go.
fn vgc_shade(addr usize, w int) {
	if addr < vgc_arena_lo || addr >= vgc_arena_hi {
		return
	}
	span := vgc_find_span(voidptr(addr))
	if span == unsafe { nil } || !span.in_use {
		return
	}
	if span.elem_size == 0 {
		return
	}
	// Find which object this address belongs to
	obj_idx := u32((addr - span.base) / usize(span.elem_size))
	if obj_idx >= span.nelems {
		return
	}
	// NOTE: the watched-object check is intentionally NOT done here — vgc_shade is
	// the hottest path (called per scanned word) and a per-word compare perturbed
	// timing enough to mask the (timing-sensitive) residual. `marked` and `swept`
	// for the watched object are derived in vgc_sweep_span instead (once per span).
	// Check if object is allocated
	if span.alloc_bits == unsafe { nil } || C.vgc_bitmap_get(span.alloc_bits, obj_idx) == 0 {
		return
	}
	// Mark it (grey -> will be scanned). More than one marker this cycle: the
	// bit is set atomically (cx-home/v#16).
	if span.mark_bits != unsafe { nil } {
		// cx-private#1910: under the concurrent collector the mutators' alloc
		// hook ORs into the same mark bytes the markers set, so the set is
		// always atomic there (a plain read-modify-write would erase a newborn's
		// mark — swept while live).
		mut was := 0
		$if vgc_concurrent ? {
			was = C.vgc_bitmap_test_and_set_atomic(span.mark_bits, obj_idx)
		} $else {
			was = if vgc_mark_nworkers_cur > 1 {
				C.vgc_bitmap_test_and_set_atomic(span.mark_bits, obj_idx)
			} else {
				C.vgc_bitmap_test_and_set(span.mark_bits, obj_idx)
			}
		}
		if was == 0 {
			$if vgc_rootdiag ? {
				vgc_rd_bytes += u64(span.elem_size)
				vgc_rd_objs++
			}
			// Newly marked - add to work queue for scanning (only if it may contain pointers)
			if !span.noscan {
				obj_addr := span.base + usize(obj_idx) * usize(span.elem_size)
				vgc_work_put(obj_addr, w)
			}
		}
	}
}

// ── -d vgc_rootdiag: which root word keeps what (cx-home/v#46) ───────────────
// A conservative root scan keeps whatever a stale word names: a spill slot or an
// uninitialised local in a live frame, a counter in the data segment that happens
// to equal an arena address. Each instance so far (cx-home/v#45's clock word,
// cx-private#1941's memo backing, the fmt_8k lane slot, #1886's joiner word) cost
// a bisect to find, and the trigger was always a codegen change elsewhere that
// moved a frame. Built with -d vgc_rootdiag, the root scan drains the mark work
// after every root word and charges the bytes newly marked to that word: a word
// reaching VGC_ROOTDIAG_MIN_KB or more (default 1024) is reported on stderr with
// its root kind, its address (the offset below the stack top, or the data
// symbol) and, on the collecting thread's own stack, the function whose frame
// holds it. A diagnostic build: the per-word drain makes the root scan slower,
// and the default build carries none of it.
__global vgc_rd_cat = u32(0)
__global vgc_rd_base = usize(0)
__global vgc_rd_own = false
__global vgc_rd_bytes = u64(0)
__global vgc_rd_objs = u64(0)
__global vgc_rd_min = u64(0)
__global vgc_rd_top_cat = u32(0)
__global vgc_rd_top_bytes = u64(0)
__global vgc_rd_top_where = usize(0)
__global vgc_rd_top_off = i64(0)

fn C.vgc_rd_report(cycle u64, cat u32, where usize, off i64, word usize, bytes u64, objs u64, own int)

fn vgc_rd_begin_cycle() {
	if vgc_rd_min == 0 {
		e := C.getenv(c'VGC_ROOTDIAG_MIN_KB')
		kb := if e != unsafe { nil } { u64(C.atoll(e)) } else { u64(1024) }
		vgc_rd_min = if kb == 0 { u64(1) } else { kb * 1024 }
	}
	vgc_rd_top_cat = 0
	vgc_rd_top_bytes = 0
	vgc_rd_top_where = 0
	vgc_rd_top_off = 0
}

// vgc_rd_shade_root shades one root word and drains what it reaches before the
// next word is read, so the bytes newly marked are this word's alone (the
// first word to reach an object is charged with it).
fn vgc_rd_shade_root(addr usize, val usize, w int) {
	cat := vgc_rd_cat
	b0 := vgc_rd_bytes
	o0 := vgc_rd_objs
	vgc_shade(val, w)
	vgc_rd_cat = 0
	vgc_drain_mark_work(w)
	vgc_rd_cat = cat
	got := vgc_rd_bytes - b0
	if got == 0 {
		return
	}
	off := if cat >= 10 { i64(vgc_rd_base) - i64(addr) } else { i64(0) }
	if got > vgc_rd_top_bytes {
		vgc_rd_top_cat = cat
		vgc_rd_top_bytes = got
		vgc_rd_top_where = addr
		vgc_rd_top_off = off
	}
	if got >= vgc_rd_min {
		C.vgc_rd_report(vgc_heap.gc_cycle, cat, addr, off, val, got, vgc_rd_objs - o0,
			if cat >= 10 && vgc_rd_own { 1 } else { 0 })
	}
}

// vgc_rootdiag_top answers the cycle's heaviest root word: its kind (1 data,
// 2 cache slots, 3 suspend records, 10 + n thread n's stack, 0 none), the bytes it
// alone reached, its address and, for a stack word, its offset below the stack
// top. Only in a -d vgc_rootdiag build.
@[markused]
pub fn vgc_rootdiag_top() (u32, u64, usize, i64) {
	return vgc_rd_top_cat, vgc_rd_top_bytes, vgc_rd_top_where, vgc_rd_top_off
}

// vgc_shade_spawn_root shades an in-flight spawn-argument struct AND unconditionally
// scans its whole object range for pointers — EVEN IF the span is noscan. V's spawn
// codegen allocates the arg struct by raw size (builtin___v_malloc(sizeof thread_arg_...),
// untyped => noscan), yet it holds the child thread's live argument pointers (e.g. a
// [?worker]'s cloned bindings/closures maps). Plain vgc_shade would MARK-but-not-TRACE it
// (the `if !span.noscan` enqueue skip), leaving those args' referents — the map key
// strings — unmarked => swept-while-live => the #58/#63 concurrent-worker UAF
// (string_clone segfault). Conservatively scanning the arg object roots the whole
// argument graph. (A spawn-root ALWAYS carries pointers, so the noscan skip is wrong here.)
fn vgc_shade_spawn_root(addr usize) {
	if addr < vgc_arena_lo || addr >= vgc_arena_hi {
		return
	}
	span := vgc_find_span(voidptr(addr))
	if span == unsafe { nil } || !span.in_use || span.elem_size == 0 {
		return
	}
	obj_idx := u32((addr - span.base) / usize(span.elem_size))
	if obj_idx >= span.nelems {
		return
	}
	if span.alloc_bits == unsafe { nil } || C.vgc_bitmap_get(span.alloc_bits, obj_idx) == 0 {
		return
	}
	if span.mark_bits != unsafe { nil } {
		C.vgc_bitmap_test_and_set(span.mark_bits, obj_idx)
	}
	obj_base := span.base + usize(obj_idx) * usize(span.elem_size)
	vgc_scan_range(obj_base, obj_base + usize(span.elem_size), 0)
}

// Parallel mark using OS threads.
// Translated from Go's gcDrain() with multiple workers.
// The markers of this cycle (cx-home/v#16): one, or the pool plus the
// collector. Decided and the pool created BEFORE the world stops.
// cx-home/v#55: the marker plan's work estimate on the collecting thread's
// CPU time. The plan engages the pool once the last mark's work reaches
// vgc_mark_par_min_ns, and a one-marker mark's work was its WALL time; with
// N processes on one box (the MP cells: 28 copies of one program) a 0.3-1.3
// ms mark read 2-8 ms of wall while it waited for a core, so every copy woke
// up to seven markers that spun on an emptied grey set and the copies scaled
// worse than Python's (json-codec 1 MB: 0.86 of Python's scaling, 1.02 with
// VGC_MARK_WORKERS=1). A one-marker mark's work is now the lesser of its wall
// and its CPU time, less the waits the cycle spun (vgc_gc_wait_cpu): a mark
// the box slowed down reads what it cost, and a large single process (its
// mark's CPU close to its wall) plans as before. A parallel mark keeps n x
// wall (vgc_mark_adapt judges whether it paid). Where there is no thread CPU
// clock (Windows) or VGC_PACER_WALL=1, the wall time, as before.
@[inline]
fn vgc_mark_cpu_begin() (u64, u64) {
	if vgc_pacer_wall != 0 || vgc_gc_cpu_t0 == 0 {
		return 0, 0
	}
	return C.vgc_thread_cpu_ns(), vgc_gc_wait_cpu
}

fn vgc_mark_work_from_cpu(cpu0 u64, wait0 u64) {
	if cpu0 == 0 {
		return
	}
	vgc_mark_work_from_cpu_at(cpu0, wait0, C.vgc_thread_cpu_ns(), vgc_gc_wait_cpu)
}

fn vgc_mark_work_from_cpu_at(cpu0 u64, wait0 u64, cpu1 u64, wait1 u64) {
	if cpu0 == 0 || vgc_mark_nworkers_cur > 1 || cpu1 <= cpu0 {
		return
	}
	mut cpu := cpu1 - cpu0
	if wait1 > wait0 {
		w := wait1 - wait0
		cpu = if w < cpu { cpu - w } else { 0 }
	}
	vgc_mark_last_cpu_ns = cpu
	if cpu < vgc_mark_last_work_ns {
		vgc_mark_last_work_ns = cpu
	}
}

fn vgc_mark_plan() int {
	if vgc_mark_workers_cfg <= 1 || vgc_mark_last_work_ns < vgc_mark_par_min_ns || vgc_mark_forked {
		return 1
	}
	mut total := vgc_mark_workers_cfg
	// One marker per vgc_mark_par_min_ns of the previous mark's work: a 3 ms
	// mark gets three markers, a 10 ms one the configured count. The whole
	// pool on a small mark is CPU for nothing — each marker's time is the
	// mark's wall time, mostly idle-spinning on an emptied grey set.
	// VGC_MARK_PAR_MIN_US=0 forces the configured count (and is no divisor:
	// x86 traps on it, arm64 reads 0 and would never engage the pool).
	by_work := if vgc_mark_par_min_ns == 0 {
		total
	} else {
		int(vgc_mark_last_work_ns / vgc_mark_par_min_ns)
	}
	if by_work < total {
		total = by_work
	}
	if vgc_mark_n_target > 0 && vgc_mark_n_target < total {
		total = vgc_mark_n_target
	}
	if total <= 1 {
		return 1
	}
	return vgc_pool_ensure(total)
}

// Grow the pool to total - 1 threads (the collector is the other one), before
// the world stops; returns the count the pool can actually field.
fn vgc_pool_ensure(total int) int {
	want := total - 1
	// a thread created now has seen every generation up to the current one;
	// this cycle's advance (vgc_pool_run) is the first it drains
	C.vgc_atomic_store_u32(&vgc_mark_spawn_gen, C.vgc_atomic_load_u32(&vgc_mark_go))
	for vgc_mark_pool_n < want {
		if C.vgc_start_thread_rc(vgc_mark_worker_main) != 0 {
			break
		}
		vgc_mark_pool_n++
	}
	if vgc_mark_pool_n + 1 < total {
		return vgc_mark_pool_n + 1
	}
	return total
}

// cx-home/v#16 (fable-v16): this cycle's walker count for clear / count /
// sweep. One walker per quarter of vgc_walk_min_spans (2048 spans, ~0.12 ms
// of serial walk on 16 KB pages), from four at the floor up to the configured
// count; one walker in a fork child, under the diagnostic builds whose sweep
// writes shared forensic tables, while an address is watched, and while the
// walks' own adaptation is backing off or the box is oversubscribed (a loaded
// box: vgc_walk_adapt, vgc_box_busy). The mark's back-off is the mark's: a
// short mark says nothing about a long table.
fn vgc_walk_plan() int {
	mut cfg := vgc_walk_workers_cfg
	if cfg < 0 {
		cfg = vgc_mark_workers_cfg
	}
	if cfg <= 1 || vgc_mark_forked || vgc_watch_addr != 0 || vgc_walk_min_spans == 0 {
		return 1
	}
	$if vgc_keysweep ? {
		return 1
	}
	$if vgc_passive ? {
		return 1
	}
	$if vgc_birthcheck ? {
		return 1
	}
	nsp := u64(vgc_heap.nspans)
	if nsp < vgc_walk_min_spans {
		return 1
	}
	mut free_cpus := 1 << 20 // VGC_WALK_LOAD_GATE=0: the configured count, uncapped
	if vgc_walk_load_gate {
		if C.vgc_box_busy(vgc_walk_ncpu) != 0 {
			return 1 // the pool would wait on a preempted walker at every join
		}
		free_cpus = C.vgc_box_free_cpus(vgc_walk_ncpu,
			int(C.vgc_atomic_load_u32(&vgc_heap.live_threads)))
	}
	mut total := int(nsp / (vgc_walk_min_spans / 4))
	if total > cfg {
		total = cfg
	}
	// no more walkers than the CPUs the rest of the box leaves free: a walker
	// without a core holds its chunk through the join (cx-home/v#16)
	if total > free_cpus {
		total = free_cpus
	}
	if vgc_walk_n_target > 0 && vgc_walk_n_target < total {
		total = vgc_walk_n_target
	}
	if total <= 1 {
		return 1
	}
	return vgc_pool_ensure(total)
}

// After the sweep: did this cycle's walkers pay off? The three walks' ns per
// table span with one walker is remembered (a running mean); a parallel cycle
// no cheaper than nine tenths of it — walkers that got no core, or one
// preempted holding a chunk through the join — halves the count for the next
// 32 parallel cycles (64, 128 ... 1024 while the retries keep not paying),
// then the plan's count is tried again (the mark's rule, vgc_mark_adapt, on
// the walks' own clock).
fn vgc_walk_adapt(walked_ns u64) {
	rate := walked_ns / (u64(vgc_heap.nspans) + 1)
	// cx-home/v#52: as the mark's (vgc_mark_adapt) — the back-off counts down
	// on every cycle, so one halved to a single walker ends too
	if vgc_walk_backoff > 0 {
		vgc_walk_backoff--
		if vgc_walk_backoff == 0 {
			vgc_walk_n_target = 0
		}
	}
	if vgc_walk_nworkers_cur <= 1 {
		vgc_walk_rate1 = if vgc_walk_rate1 == 0 { rate } else { (vgc_walk_rate1 * 7 + rate) / 8 }
		return
	}
	if vgc_walk_backoff > 0 || vgc_walk_n_target > 0 {
		return
	}
	if vgc_walk_rate1 > 0 && rate * 10 > vgc_walk_rate1 * 9 {
		mut n := vgc_walk_nworkers_cur / 2
		if n < 1 {
			n = 1
		}
		vgc_walk_n_target = n
		vgc_walk_backoff = vgc_walk_backoff_len
		if vgc_walk_backoff_len < 1024 {
			vgc_walk_backoff_len *= 2
		}
		return
	}
	vgc_walk_backoff_len = 32 // a parallel cycle that paid: the next back-off is short again
}

// After the count: did this cycle's markers pay off? The cost per marked KB
// with one marker is remembered (a running mean); a parallel cycle no cheaper
// than nine tenths of it — a loaded box where the markers get no cores, or one
// preempted marker holding the cycle's tail — halves the marker count for the
// next 32 parallel cycles, then the configured count is tried again.
fn vgc_mark_adapt(marked u64) {
	kb := marked / 1024 + 1
	rate := vgc_mark_last_ns / kb
	// cx-private#1910 cut 1: a concurrent cycle's mark is its middle, run
	// beside the mutators, so it is slower per KB than a stop-the-world mark
	// of the same heap; a parallel probe is judged against the single-marker
	// baseline of its own kind. One baseline for both let a probe of one kind
	// meet the other kind's baseline: the door's first parallel probe landing
	// on a concurrent cycle lost against the start-up's stop-the-world rate,
	// the plan halved to one marker for 32 cycles and never ramped (0 of 189
	// cycles at eight markers against bump H's 158, its stop-the-world cycles
	// marking 62 MB in 20 ms, pause p99 26-28 ms against 5-11).
	mut cm := false
	$if vgc_concurrent ? {
		cm = vgc_cm_this_cycle
	}
	// cx-home/v#52: the back-off counts down on EVERY cycle, the one-marker
	// cycles included. It counted only parallel ones, so a lost two-marker
	// probe (halved to one) was a back-off that never ended: the stores-mt
	// driver at eight threads stayed on one marker for the whole run in three
	// runs of five (a 6 ms middle against 1.1 ms, 570 ms against 220).
	if vgc_mark_backoff > 0 {
		vgc_mark_backoff--
		if vgc_mark_backoff == 0 {
			vgc_mark_n_target = 0
		}
	}
	if vgc_mark_nworkers_cur <= 1 {
		if cm {
			vgc_mark_rate1_cm = if vgc_mark_rate1_cm == 0 { rate } else { (vgc_mark_rate1_cm * 7 + rate) / 8 }
		} else {
			vgc_mark_rate1 = if vgc_mark_rate1 == 0 { rate } else { (vgc_mark_rate1 * 7 + rate) / 8 }
		}
		// cx-home/v#52: a probe judged against a baseline the start-up's small
		// heap set (145 ns/KB at 6 MB marked against 275 at 22 MB, the same
		// one marker) lost at two markers with 160 and backed off for 32
		// cycles of 275; once the one-marker cycles of the back-off move the
		// baseline past the probe's rate, the probe won after all and the
		// back-off ends
		if vgc_mark_backoff > 0 && vgc_mark_lost_rate > 0 && vgc_mark_lost_cm == cm {
			b1 := if cm { vgc_mark_rate1_cm } else { vgc_mark_rate1 }
			if vgc_mark_lost_rate * 10 <= b1 * 9 {
				vgc_mark_backoff = 0
				vgc_mark_n_target = 0
				vgc_mark_lost_rate = 0
			}
		}
		return
	}
	if vgc_mark_backoff > 0 || vgc_mark_n_target > 0 {
		return
	}
	base := if cm { vgc_mark_rate1_cm } else { vgc_mark_rate1 }
	if base > 0 && rate * 10 > base * 9 {
		mut n := vgc_mark_nworkers_cur / 2
		if n < 1 {
			n = 1
		}
		vgc_mark_n_target = n
		vgc_mark_backoff = 32
		vgc_mark_lost_rate = rate
		vgc_mark_lost_cm = cm
	}
}

// Drain the grey set with every marker of this cycle. Mutators are stopped; the
// pool threads run vgc_drain_mark_parallel for the same generation and the
// collector takes slot 0. The collector returns only when every pool thread
// has reported the cycle done, so no marker ever touches the queue outside
// this stop.
fn vgc_parallel_mark() {
	n := vgc_mark_nworkers_cur
	vgc_heap.gc_nworkers = n
	if n <= 1 {
		vgc_drain_mark_work(0)
		return
	}
	vgc_work_flush_local(0) // the roots go to the shared list, so the pool starts with work
	vgc_pool_run(vgc_pool_phase_mark, n)
}

// Run one phase of this cycle on the pool (cx-home/v#16): publish the phase
// and its thread count, advance the generation, take slot 0, and return only
// when every pool thread has reported the phase done — so no pool thread
// touches the heap outside this stop, and the next phase starts on a joined
// pool. Each phase of a cycle is one generation.
fn vgc_pool_run(phase u32, n int) {
	vgc_pool_phase = phase
	vgc_pool_phase_n = n
	C.vgc_atomic_store_u32(&vgc_mark_idle, 0)
	C.vgc_atomic_store_u32(&vgc_mark_done, 0)
	_ = C.vgc_atomic_add_u32(&vgc_mark_go, 1)
	C.vgc_mark_wake(&vgc_mark_go)
	vgc_pool_phase_run(phase, 0, n)
	if C.vgc_atomic_load_u32(&vgc_mark_done) >= u32(vgc_mark_pool_n) {
		return
	}
	// the join: slot 0 waits for the pool threads (a wait — cx-home/v#42)
	wcpu := vgc_wait_cpu_begin()
	mut spins := 0
	for C.vgc_atomic_load_u32(&vgc_mark_done) < u32(vgc_mark_pool_n) {
		spins++
		if spins > 256 {
			C.vgc_yield()
		} else {
			C.vgc_cpu_pause()
		}
	}
	vgc_wait_cpu_end(wcpu)
}

// One thread's share of a phase.
fn vgc_pool_phase_run(phase u32, slot int, n int) {
	if phase == vgc_pool_phase_mark {
		vgc_drain_mark_parallel(slot, n)
	} else if phase == vgc_pool_phase_clear {
		vgc_walk_clear(slot, n)
	} else if phase == vgc_pool_phase_count {
		vgc_walk_count(slot, n)
	} else if phase == vgc_pool_phase_sweep {
		vgc_walk_sweep(slot, n)
	} else if phase == vgc_pool_phase_rescan {
		vgc_rescan_walk(slot, n)
	}
}

// A pool thread: never registered, holds no mutator roots, allocates nothing
// from the heap. It waits on the generation, drains the cycle it was woken for
// (every pool thread is a marker of every parallel cycle), reports done.
fn vgc_mark_worker_main() {
	slot := int(C.vgc_atomic_add_u32(&vgc_mark_pool_next, 1)) // 1-based; the collector is 0
	// the generation at creation, not 0: a pool that grows after cycle G starts
	// its new threads at G, so they wait for G+1 (vgc_mark_spawn_gen above). The
	// collector cannot move it on before this read: the next plan runs only after
	// this cycle's collector has counted this thread done.
	mut seen := C.vgc_atomic_load_u32(&vgc_mark_spawn_gen)
	for {
		// The phases of one cycle follow each other within microseconds (clear,
		// then the root scan, mark, count, sweep): spin a little for the next
		// generation before sleeping on it, so a cycle pays one wake, not four.
		mut sp := 0
		for sp < 8192 && C.vgc_atomic_load_u32(&vgc_mark_go) == seen {
			C.vgc_cpu_pause()
			sp++
		}
		C.vgc_mark_wait(&vgc_mark_go, seen)
		g := C.vgc_atomic_load_u32(&vgc_mark_go)
		if g == seen {
			continue
		}
		seen = g
		ph := vgc_pool_phase
		n := vgc_pool_phase_n
		if slot < n {
			vgc_pool_phase_run(ph, slot, n)
		}
		_ = C.vgc_atomic_add_u32(&vgc_mark_done, 1)
	}
}

// Scan one grey object: every word conservatively. NOTE: precise per-span ptrmap
// scanning is UNSOUND here and was removed — a span serves one size CLASS, but
// real workloads pack many different TYPES (and conservative ptrmap==0
// allocations) into the same size class. The span records only the FIRST typed
// alloc's ptrmap (vgc_malloc_typed_opts "first typed allocation wins") and
// applies it to every object, so any object whose real pointer layout differs
// has live child pointers skipped -> reclaimed-while-reachable (observed as
// corrupted results under a deep alloc-heavy serial fold). Conservative
// scanning finds every pointer (may over-retain, never under-retains).
@[inline]
fn vgc_mark_scan_obj(obj_addr usize, w int) {
	span := vgc_find_span(voidptr(obj_addr))
	if span == unsafe { nil } || span.noscan {
		return
	}
	obj_size := usize(span.elem_size)
	vgc_scan_range(obj_addr, obj_addr + obj_size, w)
}

// Drain the mark work queue on one marker (translated from Go's gcDrain()).
fn vgc_drain_mark_work(w int) {
	for {
		obj_addr := vgc_work_get(w)
		if obj_addr == 0 {
			break
		}
		vgc_mark_scan_obj(obj_addr, w)
	}
}

// Drain as one of n markers. A marker whose local buffer and the shared list
// are both empty counts itself idle and spins (yielding the core after a
// while); the cycle's grey set is empty when every marker is idle (new work
// comes only from a marker that is not), and a marker seeing the shared list
// refilled leaves the idle count to take it. A marker holding a half-full
// buffer while others idle and the shared list is empty publishes half of it
// (Go's gcWork.balance), so the tail of a cycle is not one marker's walk.
fn vgc_drain_mark_parallel(w int, n int) {
	for {
		obj_addr := vgc_work_get(w)
		if obj_addr != 0 {
			vgc_mark_scan_obj(obj_addr, w)
			if C.vgc_atomic_load_u32(&vgc_mark_idle) > 0
				&& unsafe { voidptr(vgc_heap.work_full) } == unsafe { nil } {
				vgc_work_balance(w)
			}
			continue
		}
		_ = C.vgc_atomic_add_u32(&vgc_mark_idle, 1)
		// slot 0 (the collecting thread) waiting for the other markers is a
		// wait (cx-home/v#42); the pool threads' clocks are not the pacer's
		wcpu := if w == 0 { vgc_wait_cpu_begin() } else { u64(0) }
		mut spins := 0
		for {
			if C.vgc_atomic_load_u32(&vgc_mark_idle) >= u32(n) {
				vgc_wait_cpu_end(wcpu)
				return
			}
			if unsafe { voidptr(vgc_heap.work_full) } != unsafe { nil } {
				_ = C.vgc_atomic_sub_u32(&vgc_mark_idle, 1)
				break
			}
			spins++
			if spins > 256 {
				C.vgc_yield()
			} else {
				C.vgc_cpu_pause()
			}
		}
		vgc_wait_cpu_end(wcpu)
	}
}

// Precise pointer scanning: use the pointer bitmap to scan only
// word offsets known to contain pointers. Much faster than conservative.
fn vgc_scan_precise(obj_addr usize, ptrmap u64, ptr_words u8) {
	mut mask := ptrmap
	word_size := sizeof(usize)
	for mask != 0 {
		// Find lowest set bit (next pointer offset)
		mut bit := u8(0)
		mut m := mask
		// Count trailing zeros to find the bit position
		if m & 0xFFFFFFFF == 0 {
			bit += 32
			m >>= 32
		}
		if m & 0xFFFF == 0 {
			bit += 16
			m >>= 16
		}
		if m & 0xFF == 0 {
			bit += 8
			m >>= 8
		}
		if m & 0xF == 0 {
			bit += 4
			m >>= 4
		}
		if m & 0x3 == 0 {
			bit += 2
			m >>= 2
		}
		if m & 0x1 == 0 {
			bit += 1
		}
		// Read the pointer at this offset
		ptr_addr := obj_addr + usize(bit) * word_size
		val := unsafe { *(&usize(voidptr(ptr_addr))) }
		if val != 0 {
			vgc_shade(val, 0)
		}
		// Clear this bit and continue
		mask &= mask - 1
	}
}

// ============================================================
// Work queue (translated from Go's mgcwork.go)
// ============================================================

// The grey set (cx-home/v#16): each marker pushes to and pops from its own
// current buffer (vgc_mark_local[w], 256 slots); a full one is published to the
// shared work_full list and an empty one taken from work_empty (or carved),
// both under work_lock, so the lock is taken once per 256 objects, not per
// pointer. One marker pays the same.
@[inline]
fn vgc_work_put(addr usize, w int) {
	mut buf := unsafe { &VGC_WorkBuf(voidptr(vgc_mark_local[w])) }
	if buf == unsafe { nil } || buf.nobj >= 256 {
		C.vgc_mutex_lock(&vgc_heap.work_lock)
		if buf != unsafe { nil } {
			unsafe {
				buf.next = vgc_heap.work_full
				vgc_heap.work_full = buf
			}
		}
		mut nb := vgc_heap.work_empty
		if nb != unsafe { nil } {
			unsafe {
				vgc_heap.work_empty = nb.next
			}
		} else {
			nb = vgc_workbuf_carve()
		}
		C.vgc_mutex_unlock(&vgc_heap.work_lock)
		if nb == unsafe { nil } {
			vgc_mark_local[w] = 0
			return
		}
		unsafe {
			nb.nobj = 0
			nb.next = nil
		}
		vgc_mark_local[w] = usize(voidptr(nb))
		buf = nb
	}
	unsafe {
		buf.obj[buf.nobj] = addr
		buf.nobj++
	}
}

// Pop from the marker's buffer; when it is empty, trade it for a full one from
// the shared list. 0 = nothing local and nothing shared (the marker's empty
// buffer stays its current one).
fn vgc_work_get(w int) usize {
	mut buf := unsafe { &VGC_WorkBuf(voidptr(vgc_mark_local[w])) }
	if buf != unsafe { nil } && buf.nobj > 0 {
		unsafe {
			buf.nobj--
			return buf.obj[buf.nobj]
		}
	}
	C.vgc_mutex_lock(&vgc_heap.work_lock)
	mut fb := vgc_heap.work_full
	if fb != unsafe { nil } {
		unsafe {
			vgc_heap.work_full = fb.next
		}
		if buf != unsafe { nil } {
			unsafe {
				buf.next = vgc_heap.work_empty
				vgc_heap.work_empty = buf
			}
		}
	}
	C.vgc_mutex_unlock(&vgc_heap.work_lock)
	if fb == unsafe { nil } {
		return 0
	}
	unsafe {
		fb.next = nil
	}
	vgc_mark_local[w] = usize(voidptr(fb))
	unsafe {
		fb.nobj--
		return fb.obj[fb.nobj]
	}
}

// Move half of the marker's local buffer (when it holds at least 64 entries)
// into a buffer published on the shared list, for the idle markers.
fn vgc_work_balance(w int) {
	mut buf := unsafe { &VGC_WorkBuf(voidptr(vgc_mark_local[w])) }
	if buf == unsafe { nil } || buf.nobj < 64 {
		return
	}
	C.vgc_mutex_lock(&vgc_heap.work_lock)
	mut nb := vgc_heap.work_empty
	if nb != unsafe { nil } {
		unsafe {
			vgc_heap.work_empty = nb.next
		}
	} else {
		nb = vgc_workbuf_carve()
	}
	if nb == unsafe { nil } {
		C.vgc_mutex_unlock(&vgc_heap.work_lock)
		return
	}
	half := buf.nobj / 2
	unsafe {
		for i in 0 .. half {
			nb.obj[i] = buf.obj[buf.nobj - half + i]
		}
		nb.nobj = half
		buf.nobj -= half
		nb.next = vgc_heap.work_full
		vgc_heap.work_full = nb
	}
	C.vgc_mutex_unlock(&vgc_heap.work_lock)
}

// Publish the marker's current buffer to the shared list (the collector's root
// buffer before the pool starts), so the first pool thread to look finds work.
fn vgc_work_flush_local(w int) {
	mut buf := unsafe { &VGC_WorkBuf(voidptr(vgc_mark_local[w])) }
	if buf == unsafe { nil } {
		return
	}
	C.vgc_mutex_lock(&vgc_heap.work_lock)
	if buf.nobj > 0 {
		unsafe {
			buf.next = vgc_heap.work_full
			vgc_heap.work_full = buf
		}
	} else {
		unsafe {
			buf.next = vgc_heap.work_empty
			vgc_heap.work_empty = buf
		}
	}
	C.vgc_mutex_unlock(&vgc_heap.work_lock)
	vgc_mark_local[w] = 0
}

// ============================================================
// Write barrier (translated from Go's gcWriteBarrier / wbBufFlush)
// ============================================================

// Write barrier: called when a pointer field is written during mark phase.
// Uses Dijkstra-style insertion barrier - shade the new pointer.
fn vgc_write_barrier(new_val voidptr) {
	if C.vgc_atomic_load_u32(&vgc_heap.wb_enabled) == 0 {
		return
	}
	if new_val == unsafe { nil } {
		return
	}
	// Shade the new pointer (mark it grey)
	vgc_shade(usize(new_val), 0)
}

// vgc_wb_store is the concurrent-mark write barrier emitted by codegen (and
// called by the builtin bulk mutators) immediately BEFORE a pointer store into a
// possibly-heap location. It is a card / "dirty-span" insertion barrier: it marks
// the target object's span DIRTY (one idempotent atomic byte store), and the
// collector re-scans every dirty span at mark-termination (vgc_rescan_dirty_spans).
// Re-scanning the span conservatively shades every heap pointer its objects now
// hold — a superset of the Dijkstra insertion barrier (which shades exactly the
// newly-stored referent) — so it closes the "hide a white behind a black" hazard.
//
// Why dirty-span (not immediate shade) and why BEFORE the store: this collector
// suspends mutators with OS-level mach suspend, NOT cooperative safepoints, so a
// mutator can be frozen MID-BARRIER. An immediate-shade barrier that enqueues the
// new value to the mark queue can lose the enqueue if frozen between the slot
// write and the count bump (-> silent live reclamation). The dirty mark is a
// single store and is emitted BEFORE the pointer store, so: frozen before the
// dirty mark -> the pointer store also has not run -> no hazard; frozen after the
// dirty mark -> the span is dirty and will be re-scanned. Proven in
// bench/parallel-alloc/cm_barrier_proto.c (hazard 3: dirty-after+freeze is
// provably unsound, dirty-before is sound under every freeze).
//
// The barrier never touches the mark work queue, so during the concurrent middle
// the queue stays collector-exclusive. Off-cycle (wb_enabled == 0) it is a single
// atomic load + return; under the default build (no `vgc_concurrent` define)
// codegen emits NO calls at all, so the STW collector stays byte-identical.
//
// @[export] (not @[markused]): the only callers are codegen-emitted C (the
// per-store barrier in assign.v) + the builtin bulk mutators, so `-skip-unused`
// would otherwise prune it (it is unreferenced in the V call graph) — leaving the
// emitted `vgc_wb_store(...)` calls undeclared. Export forces retention and emits
// an early prototype under the exact C name codegen uses.
// cx-home/v#15 lever 2: wb_enabled is a mode word. Bit 0 is the concurrent
// middle (every scan span a store targets is dirtied, as above); bit 1 is the
// permanent generation's regime (vgc_perm_on, from the promotion cycle on):
// a store into a PERMANENT span dirties it in and out of a cycle, and codegen
// calls this barrier before AND after the store (assign.v
// gen_cm_write_barrier), so a dirty bit the collector cleared between the two
// calls — a cycle that ran while the right-hand side was evaluated, or a
// mutator suspended between the call and its store — is set again after the
// store landed and the next cycle re-scans the span. Off-cycle and before the
// promotion it is a single atomic load + return; the dirty bit is read before
// it is written, so a span already dirty costs no store.
@[export: 'vgc_wb_store']
pub fn vgc_wb_store(obj voidptr) {
	$if vgc_concurrent ? {
		mode := C.vgc_atomic_load_u32(&vgc_heap.wb_enabled)
		if mode == 0 {
			return
		}
		if obj == unsafe { nil } {
			return
		}
		if (mode & 1) == 0 {
			// the permanent regime alone: the page's card, set when not set
			// (vgc_perm_cards doc); the stop reads it as the span's dirty bit
			addr := usize(obj)
			if addr < vgc_perm_lo || addr - vgc_perm_lo >= vgc_perm_len || vgc_perm_cards == unsafe { nil } {
				return
			}
			card := unsafe { &u8(voidptr(usize(vgc_perm_cards) + (addr - vgc_perm_lo) / vgc_page_size)) }
			if unsafe { *card } == 0 {
				_ = C.vgc_atomic_fetch_or_u8(card, 1)
			}
			return
		}
		span := vgc_find_span(obj)
		if span != unsafe { nil } && span.in_use && !span.noscan {
			if (mode & 1) != 0 || span.perm != 0 {
				if C.vgc_atomic_load_u32(&span.dirty) == 0 {
					unsafe {
						C.vgc_atomic_store_u32(&(&VGC_Span(span)).dirty, 1)
					}
				}
			}
		}
	}
}

// Drain at most `budget` grey objects, returning the number actually scanned.
// Used by GC-assist: a mutator that allocates during the concurrent mark pays
// down a proportional slice of mark work so allocation cannot outrun marking
// (Go's gcAssist model). Returns 0 when the grey set is empty (mark is keeping up).
fn vgc_drain_mark_work_n(budget int) int {
	mut done := 0
	for done < budget {
		obj_addr := vgc_work_get(0)
		if obj_addr == 0 {
			break
		}
		span := vgc_find_span(voidptr(obj_addr))
		if span == unsafe { nil } || span.noscan {
			continue
		}
		obj_size := usize(span.elem_size)
		vgc_scan_range(obj_addr, obj_addr + obj_size, 0)
		done++
	}
	return done
}

// ============================================================
// Mark-closure verifier (DEBUG, -d vgc_verify) — soundness oracle.
// ============================================================
//
// Invariant a correct tracing collector must hold at mark termination: every
// object reachable from a MARKED (live) object is itself MARKED. If a marked
// object holds a pointer to an allocated-but-UNMARKED object, the about-to-run
// sweep will reclaim a live object -> use-after-free. This pass walks the whole
// heap once and reports every such violation. It runs entirely while the world
// is stopped (right before sweep), so it adds latency but introduces NO new race
// and does NOT change mutator/collector interleaving — the residual UAF survives
// instrumentation precisely because per-word probes shift that interleaving;
// this oracle cannot, by construction.
//
// SCAN referrer  => the real mark scanned this object yet left a child unmarked:
//                   a mark-fixpoint / work-queue-drop bug (definite).
// NOSCAN referrer => the object was allocated noscan but holds a live pointer:
//                   a noscan-misclassification candidate. (Conservative caveat:
//                   noscan bytes are not real pointers, so a value that merely
//                   *looks* like a heap pointer can false-positive; confirm via
//                   the object's size class / recorded type.)
fn vgc_verify_mark_closure() {
	mut violations := 0
	mut scan_viol := 0
	for i in 0 .. vgc_heap.nspans {
		span := unsafe { vgc_heap.allspans[i] }
		if span == unsafe { nil } || !span.in_use || span.elem_size == 0 {
			continue
		}
		if span.alloc_bits == unsafe { nil } || span.mark_bits == unsafe { nil } {
			continue
		}
		$if vgc_closlean ? {
			// #145 deep-fix A: LEAN closure check — skip NOSCAN referrer spans. They
			// produced 100% false positives (stale recycled-tail bytes misread as
			// pointers; killed by full-slot zerofill) and SCAN-type violations were
			// already 0. Scanning only SCAN spans removes the dominant cost (text/buffer
			// noscan spans are the bulk of the heap) so the check is cheap enough to run
			// every GC WITHOUT collapsing throughput -> it can coexist with the bf1 UAF
			// oracle. If this stays 0 while bf1 fires => the swept-live victim is
			// unreachable from the marked set = a ROOT miss (mark closure is sound).
			if span.noscan {
				continue
			}
		}
		for oi in 0 .. span.nelems {
			// Only marked + allocated objects are live referrers.
			if C.vgc_bitmap_get(span.alloc_bits, oi) == 0 {
				continue
			}
			if C.vgc_bitmap_get(span.mark_bits, oi) == 0 {
				continue
			}
			obj_addr := span.base + usize(oi) * usize(span.elem_size)
			end := obj_addr + usize(span.elem_size)
			mut addr := obj_addr
			for addr + sizeof(usize) <= end {
				val := unsafe { *(&usize(voidptr(addr))) }
				if val >= vgc_arena_lo && val < vgc_arena_hi {
					tspan := vgc_find_span(voidptr(val))
					if tspan != unsafe { nil } && tspan.in_use && tspan.elem_size != 0
						&& tspan.alloc_bits != unsafe { nil } && tspan.mark_bits != unsafe { nil } {
						tidx := u32((val - tspan.base) / usize(tspan.elem_size))
						if tidx < tspan.nelems && C.vgc_bitmap_get(tspan.alloc_bits, tidx) != 0
							&& C.vgc_bitmap_get(tspan.mark_bits, tidx) == 0 {
							// Marked referrer -> allocated-but-unmarked referent: closure broken.
							if violations < 40 {
								C.vgc_verify_report(u64(if span.noscan { 1 } else { 0 }),
									u64(obj_addr), u64(span.elem_size), u64(addr - obj_addr), u64(
									tspan.base + usize(tidx) * usize(tspan.elem_size)),
									u64(tspan.elem_size))
							}
							violations++
							if !span.noscan {
								scan_viol++
							}
						}
					}
				}
				addr += sizeof(usize)
			}
		}
	}
	if violations > 0 {
		// tag 0xC105 = "CLOS(ure)" total; tag 0x5CA0 = SCAN-only (definite-bug) subset.
		C.vgc_say(0xc105, u64(violations))
		C.vgc_say(0x5ca0, u64(scan_viol))
	}
}

// vgc_rootfind_active gates the per-region scan: enumerate is only invoked when
// the closure verifier found NOTHING (so any swept-while-live object is a pure
// root miss worth locating). Reset by the caller each cycle.
__global vgc_rootfind_count = u32(0)
__global vgc_segdump_done = false

// vgc_rootfind_region is the C-callback target of vgc_rootfind_enumerate: scan a
// writable, non-arena memory region [lo,hi) for pointers to allocated-but-
// UNMARKED GC objects (objects sweep is about to free). Each such pointer is a
// root the collector's mark MISSED. Classify the holder: inside a registered
// thread's live [stack_lo,stack_hi] (STACKMISS — the stack scan should have
// covered it) vs EXTERNAL (libc heap / anon mmap / TLS / a data segment
// vgc_data_segments does not enumerate — memory the GC never scans).
@[export: 'vgc_rootfind_region']
fn vgc_rootfind_region(lo usize, hi usize, kind int) {
	mut addr := (lo + sizeof(usize) - 1) & ~(usize(sizeof(usize)) - 1)
	for addr + sizeof(usize) <= hi {
		// Per-WORD arena exclusion: if the referrer location itself is GC-arena
		// memory, this is an in-arena (heap→heap) reference — the transitive case
		// the mark-closure verifier already covers, NOT an external root. (Region-
		// level exclusion is too coarse: a /proc/maps mapping can straddle the
		// arena bound.) Only NON-arena holders are true missed roots.
		if addr >= vgc_arena_lo && addr < vgc_arena_hi {
			addr += sizeof(usize)
			continue
		}
		val := unsafe { *(&usize(voidptr(addr))) }
		if val >= vgc_arena_lo && val < vgc_arena_hi {
			span := vgc_find_span(voidptr(val))
			if span != unsafe { nil } && span.in_use && span.elem_size != 0
				&& span.alloc_bits != unsafe { nil } && span.mark_bits != unsafe { nil } {
				// Skip val == span.base: the GC's own span registry (allspans / span
				// structs) holds every span's base pointer; those are bookkeeping, not
				// mutator roots, and would otherwise flood the report.
				if val != span.base {
					tidx := u32((val - span.base) / usize(span.elem_size))
					if tidx < span.nelems && C.vgc_bitmap_get(span.alloc_bits, tidx) != 0
						&& C.vgc_bitmap_get(span.mark_bits, tidx) == 0 {
						mut in_stack := 0
						for i in 0 .. vgc_heap.ncaches {
							c := unsafe { vgc_cache(i) }
							if c.registered && c.stack_lo > 0 && c.stack_hi > c.stack_lo
								&& addr >= c.stack_lo && addr < c.stack_hi {
								in_stack = 1
								break
							}
						}
						if vgc_rootfind_count < 80 {
							C.vgc_rootfind_report(u64(addr), in_stack, u64(span.base +
								usize(tidx) * usize(span.elem_size)), u64(span.elem_size),
								u64(kind))
						}
						vgc_rootfind_count++
					}
				}
			}
		}
		addr += sizeof(usize)
	}
}

// ============================================================
// Sweep phase (translated from Go's mgcsweep.go)
// ============================================================

// Sweep all spans synchronously.
fn vgc_do_sweep() {
	$if vgc_passive ? {
		// #58 SWEEP-TIME coverage re-check: mark-time coverage (0x57ab) is not
		// enough — a peer that un-parks MID-GC mutates between mark and sweep
		// (the where-is-it forensic found victim pointers on frozen stacks that
		// mark never saw => written after mark). Any registered non-self peer
		// that is neither self-parked nor acked-suspended AT SWEEP START is the
		// leaker: 0x57ac + slot index.
		swp_self := C.vgc_get_cache_idx()
		for ci in 0 .. vgc_heap.ncaches {
			cc := unsafe { vgc_cache(ci) }
			if !cc.registered || ci == swp_self || cc.mach_port == 0 {
				continue
			}
			parked_now := C.vgc_atomic_load_u32(&vgc_cache(ci).stopped) != 0
				&& cc.park_seq == C.vgc_atomic_load_u32(&vgc_heap.gc_stop_seq)
			if !parked_now && C.vgc_slot_is_acked(ci) == 0 {
				C.vgc_say(0x57ac, u64(u32(ci)))
			}
		}
	}
	$if vgc_keysweep ? {
		unsafe { C.memset(&vgc_ks_tab[0], 0, usize(sizeof(usize)) * usize(vgc_ks_cap)) }
		vgc_ks_count = 0
		vgc_ks_overflow = 0
	}
	// cx-home/v#16: the per-span bit work on the pool, then the verdicts
	// (recycle / relink) applied here, by this thread, in slot order.
	C.vgc_atomic_store_u32(&vgc_walk_active, 1)
	vgc_walk_run(vgc_pool_phase_sweep)
	C.vgc_atomic_store_u32(&vgc_walk_active, 0)
	t_walked := C.vgc_now_ns()
	vgc_ph_swalk_ns = t_walked - vgc_ph[6]
	vgc_walk_sweep_apply()
	vgc_ph_sapply_ns = C.vgc_now_ns() - t_walked
	$if vgc_keysweep ? {
		// #58 FORENSIC (world still stopped, sweep just freed): does any REGISTERED
		// thread's scanned window STILL hold a word pointing into an object this
		// sweep freed (scan-class, keys-array-sized)? A hit is the smoking gun for
		// a mark-pipeline miss — the root was VISIBLE at sweep time yet its object
		// was reclaimed — with the exact holder word address. No hits while the
		// DEAD-KEYS interpreter probe still fires means the roots were NOT on any
		// stack during the GC (a stale env copy written after the fact).
		if vgc_ks_count > 0 {
			ks_self := C.vgc_get_cache_idx()
			for ti in 0 .. vgc_heap.ncaches {
				if ti == ks_self {
					// The COLLECTOR's own frames evolved since its mark-time snapshot
					// (sweep locals legitimately reference freed objects) — skip self;
					// only the frozen mutators' windows are meaningful here.
					continue
				}
				tc := unsafe { vgc_cache(ti) }
				if !tc.registered || tc.stack_lo == 0 || tc.stack_hi <= tc.stack_lo {
					continue
				}
				mut w := (tc.stack_lo + sizeof(usize) - 1) & ~(usize(sizeof(usize)) - 1)
				for w + sizeof(usize) <= tc.stack_hi {
					val := unsafe { *(&usize(voidptr(w))) }
					if val >= vgc_arena_lo && val < vgc_arena_hi {
						if vgc_ks_lookup(val) {
							C.vgc_say(0x5ee9, u64(w)) // holder word (on a scanned stack!)
							C.vgc_say(0x5eea, u64(val)) // the freed object it points to
							C.vgc_say(0x5eeb, u64(u32(ti))) // holder thread cache idx
						}
					}
					w += sizeof(usize)
				}
			}
			if vgc_ks_overflow != 0 {
				C.vgc_say(0x5eec, u64(vgc_ks_overflow)) // candidates dropped (buffer full)
			}
		}
	}
	// cx #360: return long-cold pooled spans' pages to the OS (aged + budgeted;
	// see vgc_pool_trim). After the sweep so this cycle's fresh empties are
	// pooled (and start aging) before the walk. An explicit gc_collect() cycle
	// instead returns the WHOLE pool (cx #52; see vgc_force_collect_release_os).
	// #1892: a frag gate deferred an arena carve to this collection — merge the
	// pool's adjacent free spans first, so the retried request finds its run
	// (and the trim below sees the merged spans).
	// cx-home/v#14: an in-arena carve beside an idle pool asked for the idle
	// runs only (spans pooled by an earlier sweep and not re-popped since); a
	// frag-gate request merges everything and covers it.
	vgc_idle_defrag_merged_kb = 0
	if C.vgc_atomic_load_u32(&vgc_defrag_pending) != 0 {
		C.vgc_atomic_store_u32(&vgc_defrag_pending, 0)
		C.vgc_atomic_store_u32(&vgc_idle_defrag_pending, 0)
		vgc_idle_defrag_merged_kb = vgc_pool_defrag(0) / 1024
	} else if C.vgc_atomic_load_u32(&vgc_idle_defrag_pending) != 0 {
		C.vgc_atomic_store_u32(&vgc_idle_defrag_pending, 0)
		vgc_idle_defrag_merged_kb = vgc_pool_defrag(vgc_idle_defrag_age) / 1024
	}
	if C.vgc_atomic_load_u32(&vgc_eager_trim_pending) != 0 {
		C.vgc_atomic_store_u32(&vgc_eager_trim_pending, 0)
		vgc_pool_trim_all()
	} else {
		vgc_pool_trim()
	}
	C.vgc_atomic_store_u32(&vgc_heap.sweep_done, 1)
}

// Sweep a single span: free unmarked objects.
// Translated from Go's mspan.sweep() in mgcsweep.go.
// cx-home/v#16: split into the per-span bit work (vgc_sweep_span_bits, run by
// any walker) and the list work its verdict asks for (vgc_sweep_span_apply,
// the collector only). This serial form is what vgc_sweep_finish uses.
fn vgc_sweep_span(span &VGC_Span) {
	vgc_sweep_span_apply(span, vgc_sweep_span_bits(span))
}

// The bit work of one span's sweep: clear the garbage bits, fix alloc_count
// and the free_index hint, and return the verdict — recycle (empty, not
// acquired this cycle), relink (survivors and free slots, off every list) or
// nothing. Touches only this span.
fn vgc_sweep_span_bits(span &VGC_Span) u8 {
	if span.alloc_bits == unsafe { nil } || span.mark_bits == unsafe { nil } {
		return vgc_walk_tag_none
	}
	// #58 ROOT CAUSE (quiet half — the workers8 sweep-while-live UAF): a mutator
	// can be SIGNAL-FROZEN (async-suspend STW stops threads at ARBITRARY PCs)
	// inside the allocation fast path BETWEEN its atomic alloc-bit claim and the
	// point where the new object's address exists in any scannable location
	// (registers/stack). During that window the slot is alloc=1/mark=0 — to this
	// sweep it is indistinguishable from garbage — so the bit was CLEARED under
	// the in-flight claim; the resumed thread completed the claim and handed out
	// a slot the allocator would hand out AGAIN => two live owners => torn
	// structs / bit-clear reads (the 0xbf1 oracle) / string_clone segfaults.
	// alloc-black cannot close this: it is phase-gated at the claim, and the
	// freeze happens BEFORE the cycle starts (the mark-bit wipe at cycle start
	// likewise erases any pre-set mark). The airtight invariant instead: every
	// span a mutator can be mid-claim in RIGHT NOW is exactly the set stamped
	// sweep_gen == gc_cycle (cache-resident spans + the tiny-cursor owner via
	// vgc_protect_cached_spans; freshly acquired spans via span_init/central_get).
	// Skip sweeping those spans entirely this cycle. Their garbage is reclaimed
	// one cycle late, and the delay is self-limiting: unreclaimed slots keep
	// their alloc bits, so the span fills, gets evicted from the cache, loses its
	// stamp, and the NEXT sweep reclaims it normally.
	if span.sweep_gen == u32(vgc_heap.gc_cycle) {
		return vgc_walk_tag_none
	}
	// cx-home/v#37: a span in flight to its owner — popped from a list, not yet
	// in the owner's slot — however many cycles the owner is off-CPU. (The
	// stamp above covered that window for one sweep only.)
	if C.vgc_atomic_load_u32(&span.inflight) != 0 {
		return vgc_walk_tag_none
	}

	// Sweep using byte-level operations for speed
	nbytes := (span.nelems + 7) / 8
	mut freed := u32(0)
	mut new_free_index := span.nelems // will be set to lowest freed index

	// DIAGNOSTIC: compute the watched object's bit position within this span (if any).
	mut watch_byte := u32(0xffffffff)
	mut watch_bit := u8(0)
	if vgc_watch_addr != 0 && span.elem_size != 0 && vgc_watch_addr >= span.base
		&& vgc_watch_addr < span.base + usize(span.nelems) * usize(span.elem_size) {
		w_idx := u32((vgc_watch_addr - span.base) / usize(span.elem_size))
		watch_byte = w_idx >> 3
		watch_bit = u8(1) << (w_idx & 7)
	}

	for b in 0 .. nbytes {
		alloc_byte := unsafe { span.alloc_bits[b] }
		mark_byte := unsafe { span.mark_bits[b] }
		// allocated but not marked = garbage
		garbage := alloc_byte & ~mark_byte
		$if vgc_concurrent ? {
			// cx-home/v#15: a swept candidate leaves the epoch (its slot's next
			// occupant is born after vgc_set_permanent)
			if garbage != 0 && span.perm_cand != unsafe { nil } {
				unsafe {
					cp := &u8(voidptr(usize(span.perm_cand) + usize(b)))
					*cp = *cp & ~garbage
				}
			}
		}
		if b == watch_byte {
			// DIAGNOSTIC (per-span, cheap): record this cycle's mark/sweep verdict
			// for the watched object. marked = its mark bit is set at sweep time;
			// swept = it was allocated-but-unmarked and is being freed now.
			if (mark_byte & watch_bit) != 0 {
				vgc_watch_marked = 1
			}
			if (garbage & watch_bit) != 0 {
				vgc_watch_swept = 1
				// RECLAMATION CYCLE CAUGHT: emit this cycle's root-scan localizers so
				// we see exactly why the watched object was not marked. All-zero
				// (in_stack/in_reg/in_spawn/rng_cov) ⇒ NO scanned root held it = a
				// genuine root-scan miss; nonzero with marked==0 ⇒ a root held it but
				// the mark dropped it. byte0=in_stack byte1=in_reg byte2=in_spawn
				// byte3=rng_cov (each = thread idx+1, or 0).
				roots := u64(vgc_watch_in_stack & 0xff) | (u64(vgc_watch_in_reg & 0xff) << 8) | (u64(vgc_watch_in_spawn & 0xff) << 16) | (u64(vgc_watch_rng_cov & 0xff) << 24)
				C.vgc_say(0x5eed, roots) // SWEEP-of-watched: localizer bitfield
				$if cx_watch_keytext ? {
					// #145 deep-fix A: on a captured-but-swept verdict (a scanned root
					// held this buffer yet it is being freed unmarked) dump the buffer
					// TEXT (still mapped under -d vgc_nosweep) so the exact victim key is
					// named. Rare (only the watched obj, only when root-held) -> no
					// collector slowdown, non-masking.
					if roots != 0 {
						n := if span.elem_size < u32(24) { span.elem_size } else { u32(24) }
						C.vgc_say(0x5e1d, roots) // duplicate to flag the rooted-victim case
						C.write(2, c'[watch-rooted-swept] ', usize(21))
						C.write(2, voidptr(vgc_watch_addr), usize(n))
						C.write(2, c'\n', usize(1))
					}
				}
			}
		}
		if garbage != 0 {
			freed += u32(C.vgc_popcount8(garbage))
			$if vgc_keysweep ? {
				// #58 forensic: record every scan-class keys-array-sized object this
				// sweep frees, for the post-sweep registered-window rescan. Keys
				// arrays of the victim-class small maps live in the 128-192B classes
				// (DenseArray init cap 8 x 16B string structs + one 1.125x expand).
				// The wider nets overflowed the candidate buffer every cycle (the
				// heap is goal-sized, not floor-sized), silently voiding the negative
				// verdict. Precision beats breadth here.
				if !span.noscan && span.elem_size >= u32(128) && span.elem_size <= u32(192) {
					for kbit in 0 .. 8 {
						if garbage & (u8(1) << kbit) != 0 {
							koi := u32(b) * 8 + u32(kbit)
							if koi < span.nelems {
								vgc_ks_insert(span.base + usize(koi) * usize(span.elem_size))
							}
						}
					}
				}
			}
			$if vgc_passive ? {
				$if !vgc_nosweep ? {
					// #63/#145 PASSIVE: record each freed SMALL noscan buffer (the
					// map-key char-buffer victim class) at its TRUE freeing GC into the
					// swept-log for GOLD correlation. PURELY PASSIVE — alloc bits are
					// still cleared below (no retention), so the crash/UAF is preserved.
					// Bit-loop only over small noscan spans, bounded STW cost.
					if span.noscan && span.elem_size <= u32(32) {
						for bit in 0 .. 8 {
							if garbage & (u8(1) << bit) != 0 {
								oi := u32(b) * 8 + u32(bit)
								if oi < span.nelems {
									vgc_slog_record(span.base + usize(oi) * usize(span.elem_size),
										span.elem_size)
								}
							}
						}
					}
				}
			}
			// Clear the garbage bits from the alloc bitmap. ATOMIC AND of exactly
			// ~garbage (NOT a plain write-back of `alloc_byte & mark_byte`): the
			// plain store publishes a value computed from a byte read earlier in
			// this loop, so any claim (vgc_span_alloc_obj's atomic OR) that lands
			// between that read and this store is silently ERASED — the object is
			// born with its bit verified set, then reads dead within the same GC
			// cycle with no sweep or free in between (#57/#58/#63/#145 lineage;
			// proven by the birth-certificate forensic: birth_dcyc==0, 0xa110==0,
			// free-ring silent). Under a truly stopped world the two forms are
			// identical; when any mutator is still running (however it slipped the
			// STW net), the atomic AND clears only the swept bits and cannot eat a
			// concurrent claim. Defense-in-depth with zero extra cost.
			$if vgc_birthcheck ? {
				vgc_bw_check(usize(span.alloc_bits) + usize(b), garbage, 0xc1ea2)
			}
			$if vgc_sweep_plain ? {
				// A/B isolation switch: the historical plain write-back.
				unsafe {
					span.alloc_bits[b] = alloc_byte & mark_byte
				}
			} $else {
				unsafe {
					_ = C.vgc_atomic_fetch_and_u8(&u8(voidptr(usize(span.alloc_bits) + usize(b))),
						~garbage)
				}
			}
			// Track lowest freed index for free_index hint
			base_idx := b * 8
			if u32(base_idx) < new_free_index {
				new_free_index = u32(base_idx)
			}
		}
	}

	if freed > 0 {
		unsafe {
			(&VGC_Span(span)).alloc_count -= freed
			if new_free_index < span.free_index {
				(&VGC_Span(span)).free_index = new_free_index
			}
		}
	}

	// If span is completely empty, recycle it to the free span pool. But FIRST
	// unlink it from any central partial/full list it is on — vgc_put_free_span
	// reuses span.next for the free_spans chain, so recycling a still-linked span
	// would splice free_spans into the central list and a later vgc_central_get_span
	// would traverse a garbage node -> wild span -> SIGSEGV. Safe to touch the
	// central lists here: vgc_gc_start holds every central[].lock across the cycle.
	//
	// sweep_gen GUARD: never reclaim a span ACQUIRED this same GC cycle. A mutator
	// that just got a fresh/recycled span (vgc_span_alloc/central_get_span set
	// span.sweep_gen = gc_cycle) but was suspended mid-vgc_span_init — after
	// mark_bits=mmap, with alloc_count still 0 and the span already in allspans —
	// would otherwise look "empty" here and be freed (mark_bits munmap'd, base
	// decommitted); on resume the mutator's span_init memset hits the freed page ->
	// SIGSEGV. Giving an in-flight span a one-cycle grace closes that window (a span
	// genuinely emptied this cycle is reclaimed on the next, a bounded delay).
	if span.alloc_count == 0 && span.npages > 0 && span.sweep_gen != u32(vgc_heap.gc_cycle) {
		return vgc_walk_tag_recycle
	}
	if span.alloc_count > 0 && span.alloc_count < span.nelems && span.on_central == 0
		&& span.class_idx != 0 {
		return vgc_walk_tag_relink
	}
	return vgc_walk_tag_none
}

// The list work of one span's sweep, by the collector after the walk's join
// (cx-home/v#16): an empty span leaves its central list and goes to the pool;
// a partial span off every list is relinked onto its class's partial list.
// The conditions were decided in vgc_sweep_span_bits; the comments below are
// the serial sweep's, and still hold: the collector holds every central lock
// and free_spans_lock across the cycle.
fn vgc_sweep_span_apply(span &VGC_Span, tag u8) {
	if C.vgc_atomic_load_u32(&vgc_walk_active) != 0 {
		C.vgc_say(0x3a1e, u64(span.slot)) // list work inside the walk
		C.abort()
	}
	if tag == vgc_walk_tag_recycle {
		mut mspan := unsafe { &VGC_Span(span) }
		if mspan.on_central != 0 {
			sc := int(mspan.class_idx) * 2 + if mspan.noscan { 1 } else { 0 }
			unsafe {
				if mspan.prev != nil {
					mspan.prev.next = mspan.next
				} else if mspan.on_central == 1 {
					vgc_heap.central[sc].partial = mspan.next
				} else {
					vgc_heap.central[sc].full = mspan.next
				}
				if mspan.next != nil {
					mspan.next.prev = mspan.prev
				}
				mspan.on_central = 0
				mspan.next = nil
				mspan.prev = nil
			}
		}
		vgc_put_free_span(mut mspan)
		return
	}

	// cx #360: a swept small span that still has BOTH survivors and free slots is
	// re-linked onto its class's central partial list, so allocation refills from
	// its free slots (vgc_central_get_span pops partial first) instead of carving
	// fresh arena space. NOTHING else repopulates central.partial: the mcache
	// drop-when-full path (B18) deliberately returns nothing, so before this
	// relink any span evicted with >=1 survivor was stranded until fully empty —
	// one 16 B long-lived object pinned an entire 8 KB span out of circulation
	// (512x amplification), which is how a flat ~25 MB live set stranded hundreds
	// of MB of committed spans and ratcheted arenas/RSS monotonically (#360).
	// SAFE HERE: the collector holds every central[].lock across the cycle (taken
	// in vgc_gc_start before the world stopped), so the list op is exclusive; the
	// span passed the sweep_gen guard above, so it is NOT mcache-resident (those
	// are stamped by vgc_protect_cached_spans and returned early) and not freshly
	// acquired this cycle; on_central==0 means it has no list membership to
	// corrupt. A span already on partial (on_central==1, relinked by an earlier
	// cycle and not yet popped) keeps its place. Large spans (class_idx 0,
	// nelems 1) never qualify — alloc_count>0 means they are full — but the
	// class_idx guard makes the exclusion explicit.
	if tag == vgc_walk_tag_relink {
		sc := int(span.class_idx) * 2 + if span.noscan { 1 } else { 0 }
		if sc < 136 {
			mut pspan := unsafe { &VGC_Span(span) }
			unsafe {
				pspan.next = vgc_heap.central[sc].partial
				pspan.prev = nil
				if pspan.next != nil {
					pspan.next.prev = pspan
				}
				vgc_heap.central[sc].partial = pspan
				pspan.on_central = 1
			}
		}
	}
}

// Ensure all sweeping from previous cycle is done
fn vgc_sweep_finish() {
	if C.vgc_atomic_load_u32(&vgc_heap.sweep_done) == 0 && vgc_heap.gc_cycle > 0 {
		// Sweep any remaining spans
		for vgc_heap.sweep_idx < vgc_heap.nspans {
			idx := vgc_heap.sweep_idx
			vgc_heap.sweep_idx = idx + 1
			span := unsafe { vgc_heap.allspans[idx] }
			if span != unsafe { nil } && span.in_use {
				vgc_sweep_span(span)
			}
		}
		C.vgc_atomic_store_u32(&vgc_heap.sweep_done, 1)
	}
}

// ============================================================
// GC Pacer (translated from Go's mgcpacer.go gcController)
// ============================================================

// Count total marked bytes across all spans using byte-level popcount
fn vgc_count_marked() u64 {
	// cx-home/v#16: on the pool when the table is large (vgc_walk_count)
	for w in 0 .. vgc_max_markers {
		vgc_walk_sum[w * 16] = 0
	}
	vgc_walk_run(vgc_pool_phase_count)
	mut total := u64(0)
	for w in 0 .. vgc_max_markers {
		total += vgc_walk_sum[w * 16]
	}
	return total
}

// Adaptation thresholds for the #71 adaptive headroom (see the vgc_headroom
// doc block): grow when the cycle cost exceeds ~1/10 (10%) of the mutator time
// since the previous cycle, shrink below ~1/50 (2%). The dead band between them
// prevents flapping; x2 steps traverse min..ceiling in a handful of cycles.
// The band is deliberately TIME-generous (boehm-like: space stays proportional
// unless GC time is severe). A tighter 2%-grow trigger measured WORSE on both
// axes: on a dev-build (-O0) reactor under loopback hammer (pause ~3-5ms) it
// rode the many-threaded ceiling to ~1.1 GB RSS, and on the t=4 pure-alloc
// bench the 768 MB equilibrium it picked was slower than a pinned 256 MB
// (12.07 vs 11.09 Mops/s) — headroom growth stops paying once the pause is
// span-walk-dominated, so demanding <2% overhead just burns space for nothing.
const vgc_overhead_grow_div = u64(10)
const vgc_overhead_shrink_div = u64(50)

// Update the GC trigger point for the next cycle. Runs under STW, right after
// sweep — the only writer of next_gc / headroom / cycle timestamps.
// Goal = marked + max(headroom, marked * GOGC/100), clamped to the soft limit.
// The GOGC term is Go's gcControllerState.endCycle() proportional growth (it
// dominates for large live sets — unchanged behavior). The headroom term is
// the cx #71 adaptive replacement for the old fixed 256 MB absolute floor +
// check-time per-thread additive: it decides how much DEAD transient growth a
// small-live-set program accumulates between backstop cycles, sized by what
// collections actually cost here and now rather than by a static guess.
// The registered threads that allocated since the previous cycle (their
// alloc_gen stamp is this cycle's number; the world is stopped here).
fn vgc_alloc_threads() int {
	mut n := 0
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { vgc_cache(i) }
		if c.registered && c.alloc_gen == u32(vgc_heap.gc_cycle) {
			n++
		}
	}
	return n
}

fn vgc_update_trigger() {
	marked := C.vgc_atomic_load_u64(&vgc_heap.heap_marked)
	gc_percent := u64(vgc_heap.gc_percent)

	$if !windows {
		if vgc_test_stall_us > 0 {
			C.usleep(u32(vgc_test_stall_us))
		}
	}
	now := C.vgc_now_ns()
	// The adaptive floor (cx-home/v#14; vgc_headroom_adaptive_floor doc):
	// clamp(2 x marked, lo, live_floor). hr_min follows it below 8 MB.
	mut afloor := vgc_headroom_live_floor
	mut hr_min := vgc_headroom_min
	// The threads that allocated this cycle (cx-home/v#16), read here because
	// the floor depends on it (cx-home/v#14 below). Never on the first
	// collection (cx-core-code#123: its cycle is the program's start-up).
	mut nt := 1
	if vgc_headroom_per_thread && vgc_heap.gc_cycle > 0 {
		nt = vgc_alloc_threads()
	}
	if vgc_headroom_adaptive_floor && !vgc_headroom_pinned && vgc_headroom_live_pct > 0 {
		// cx-home/v#14, cx-private#1886: ONE allocating thread paces to Go's
		// GOGC=100 goal, clamp(1 x marked, vgc_headroom_floor_lo1, live_floor),
		// so a 1-2 MB live set runs a 3-4 MB goal, not 5-6 MB (3x marked under
		// the 4 MB clamp): fasta 19.5 -> 17.4 MB (Python 8.8), pi-digits
		// 25.0 -> 18.8 (9.8), json-codec 66-74 -> 59.5 (32-36), at about twice
		// the collections of a cycle that costs 0.45-0.6 ms. Several allocating
		// threads keep clamp(2 x marked, vgc_headroom_floor_lo, live_floor) as
		// the base the per-thread scaling multiplies (integrator ruling
		// 2026-10-11T08:19:47Z: that scaling is bounded by the live set only
		// after the cx-private#1910 cycle-cost work).
		mut f := marked * 2
		mut lo := vgc_headroom_floor_lo
		if nt <= 1 {
			f = marked * vgc_goal_live_pct / 100
			lo = vgc_headroom_floor_lo1
		}
		if f < lo {
			f = lo
		}
		if f < afloor {
			afloor = f
		}
		if hr_min > afloor {
			hr_min = afloor
		}
	}
	if !vgc_headroom_pinned {
		// Cycle cost vs mutator progress. pause = this cycle (t0 stamped at the
		// winning gc_phase CAS, so it includes the stop protocol + mark + sweep);
		// interval = mutator wall time between the previous cycle's end and this
		// cycle's start. Monotonic clock, but guard the subtractions anyway — a
		// zero pause/interval just falls into the shrink/grow branch harmlessly.
		mut pause := u64(0)
		if vgc_gc_t0 != 0 && now > vgc_gc_t0 {
			pause = now - vgc_gc_t0
		}
		mut interval := u64(0)
		if vgc_gc_t0 > vgc_gc_last_end {
			interval = vgc_gc_t0 - vgc_gc_last_end
		}
		// cx-home/v#42: the cost is the collecting thread's CPU time over the
		// cycle (it runs every phase and marks as slot 0 of the pool), not its
		// wall time: on a busy box the stop, the wakes and the collector's own
		// slices wait for a core, and a 4.5 ms pause read 65-70 ms with no
		// extra work — the band then bought headroom (RSS) and the gates stood
		// down for load the program did not make. The interval stays the
		// mutators' wall time (an idle server's interval is idle, and GC that
		// is cheap against it is cheap). Go's GC CPU limiter has this shape:
		// the collector's CPU, not its wall time. No CPU clock (Windows) or
		// VGC_PACER_WALL=1: the wall pause, as before.
		if vgc_pacer_wall == 0 && vgc_gc_cpu_t0 != 0 {
			cpu_now := C.vgc_thread_cpu_ns()
			if cpu_now > vgc_gc_cpu_t0 {
				// the waits' spin is the box's contention, not the cycle's work
				// (FreeBSD CI: 179-790 ms of CPU spun waiting for descheduled
				// markers and parkers in cycles whose work is ~3 ms)
				mut cpu := cpu_now - vgc_gc_cpu_t0
				if vgc_gc_wait_cpu < cpu {
					cpu -= vgc_gc_wait_cpu
				} else {
					cpu = 0
				}
				if cpu < pause {
					pause = cpu
				}
			}
		}
		vgc_gate_last_pause = pause
		vgc_gate_last_interval = interval
		mut hr := vgc_headroom
		if pause * vgc_overhead_grow_div > interval {
			hr *= 2 // GC overhead > ~2%: buy throughput with space
			vgc_headroom_floor_capped = false
		} else if pause * vgc_overhead_shrink_div < interval {
			hr /= 2 // GC overhead < ~0.25%: collections are cheap, collect eagerly
			vgc_headroom_floor_capped = true
		}
		// Ceiling = a flat, deliberately SMALL cap (see the vgc_headroom_cap doc:
		// growing past it measured as pure space burn on every workload probed —
		// the pause is span-walk-dominated up there, so more headroom does not
		// reduce the overhead ratio). Floor = vgc_headroom_min (8 MB default).
		mut hr_max := vgc_headroom_cap
		// cx-core-code#123: nt is 1 on the first collection (read above). Its
		// cycle is the program's start-up (the runtime and the program loading
		// on the main thread before the work moves to its own threads), so two
		// threads that each flushed a start-up megabyte doubled the second
		// cycle's floor to 8 MB, and that cycle's free pool stayed resident.
		if vgc_headroom_per_thread && vgc_heap.gc_cycle > 0 {
			// cx-home/v#16: the threads that allocated this cycle scale the flat
			// cap too — x ceil(nt / 4), at most x4 (eight threads: 128 MB; the
			// reference, Python's multiprocessing, spends eight heaps).
			if nt > 4 {
				mut mult := u64((nt + 3) / 4)
				if mult > 4 {
					mult = 4
				}
				hr_max *= mult
			}
		}
		if hr_max > vgc_heap_soft_limit {
			hr_max = vgc_heap_soft_limit
		}
		if vgc_headroom_live_pct > 0 {
			mut live_cap := marked * vgc_headroom_live_pct / 100
			mut floor := afloor
			if vgc_headroom_per_thread && nt > 1 {
				// cx-home/v#16: floor x the threads that allocated this cycle —
				// cx-private#1910 (integrator ruling 08:19:47Z 10-11): only up to
				// 4 x the marked set WHILE the collections are cheap. The
				// per-thread headroom is a grace for threads that each flush a
				// working set; past 4 x live it is idle space (xap#20 at 10k TLS:
				// 18-38 MB marked carried 128-192 MB of it) — but only where the
				// cycles cost the mutator nothing. The cap bites once the band
				// above read the overhead under ~0.25 % (collections are cheap)
				// and lifts once it read over ~2 % (the full per-thread floor
				// is the bound again, so hr doubles back up to it); in between
				// the last reading stands. An unconditional cap held the k=8
				// http-json-echo (2 MB marked, 10 allocating threads: a 3 ms
				// stop every cycle, the mark too small for the concurrent
				// cycle) to 8 MB of headroom against 32-40: 2.5-2.8x the
				// collections and 79k -> 57-62k req/s on a quiet box
				// (cx-private#1910 PERF-EVID, 2026-10-11).
				floor *= u64(nt)
				if vgc_headroom_floor_capped {
					mut cap := marked * 4
					if cap < afloor {
						cap = afloor
					}
					if floor > cap {
						floor = cap
					}
				}
			}
			if live_cap < floor {
				live_cap = floor
			}
			if hr_max > live_cap {
				hr_max = live_cap
			}
		}
		if hr < hr_min {
			hr = hr_min
		}
		if hr > hr_max {
			hr = hr_max
		}
		vgc_headroom = hr
	}
	vgc_gc_last_end = now

	mut extra := marked * gc_percent / 100
	if extra < vgc_headroom {
		extra = vgc_headroom
	}
	mut goal := marked + extra
	// the grow gate's credit (cx-private#1916, vgc_d_vgc.c.v)
	vgc_grow_gate_credit += vgc_grow_gate_rate_pct * 10
	if vgc_grow_gate_credit > 2000 {
		vgc_grow_gate_credit = 2000
	}
	// A grow-gate probe that found the cycle's allocation mostly live gives the
	// next cycle the budget it cut (cx-home/v#7, vgc_d_vgc.c.v).
	if vgc_grow_gate_probe_armed {
		vgc_grow_gate_probe_armed = false
		pm := vgc_grow_gate_probe_marked
		pl := vgc_grow_gate_probe_live
		pg := vgc_grow_gate_probe_goal
		if pg > pl && pl > pm && marked > pm && (marked - pm) * 2 >= pl - pm {
			goal += pg - pl
		}
	}
	// Clamp to the soft heap limit: the backstop must keep firing well before the
	// physical arena ceiling regardless of how large the marked set gets (#57/#71).
	if goal > vgc_heap_soft_limit {
		goal = vgc_heap_soft_limit
	}
	// Clamp to the effective PHYSICAL capacity too (cx-private#937). The soft
	// limit is a fixed 2 GB default deliberately NOT derived from the arena
	// ceiling — but when VGC_MAX_ARENAS lowers the physical capacity BELOW the
	// soft limit, an unclamped goal (marked + the GOGC term) can exceed what
	// the arenas can ever hold: paced collection then never engages, and every
	// allocation past capacity rides the span-exhaustion force-collect — the
	// fragmentation-sensitive lane (measured: 143 MB live under a 4-arena
	// 256 MB cap paced to a 286 MB goal, and a 2 MB large alloc died in
	// vgc_alloc_large after retry). Pace to 7/8 of capacity so the backstop
	// fires before the wall; the cx #272 minimum-progress budget below still
	// lifts the goal for live sets AT the cap, so they overshoot by marked/16
	// and hit the honest hard wall instead of livelocking.
	phys_cap := u64(vgc_max_arenas_eff) * u64(vgc_arena_size)
	if phys_cap > 0 {
		pace_cap := phys_cap - phys_cap / 8
		if goal > pace_cap {
			goal = pace_cap
		}
	}
	// Guaranteed progress under the clamp (cx #272): once the marked set reaches
	// the soft limit, a clamped goal sits AT or BELOW heap_live, so every
	// allocation-side pacing check fires a full collection — a mutator livelock,
	// not pacing (measured: marked 594 MB vs a 512 MB limit ran 3286 back-to-back
	// cycles, 99.6% of wall time paused, on a workload that completes in ~1 s
	// unclamped). The soft limit is a pacing target, not a hard cap (the hard cap
	// stays the physical arena ceiling + span-exhaustion force-collect), so when
	// the live set alone exceeds it, overshoot by a minimum mutator budget —
	// 1/16th of the live set (Go's GOMEMLIMIT keeps an analogous minimum headroom
	// under its limit) with the adaptive floor as the small-heap lower bound.
	// Goals already more than that budget under the limit are untouched.
	mut min_budget := marked / 16
	if min_budget < hr_min {
		min_budget = hr_min
	}
	if goal < marked + min_budget {
		goal = marked + min_budget
	}
	C.vgc_atomic_store_u64(&vgc_heap.next_gc, goal)
}

// ============================================================
// Heap usage reporting
// ============================================================

fn vgc_heap_usage() (usize, usize, usize, usize, usize) {
	live := C.vgc_atomic_load_u64(&vgc_heap.heap_live)
	total_alloc := C.vgc_atomic_load_u64(&vgc_heap.total_alloc)
	// Count actual in-use span pages as heap size
	mut in_use_bytes := usize(0)
	for i in 0 .. vgc_heap.nspans {
		span := unsafe { vgc_heap.allspans[i] }
		if span != unsafe { nil } && span.in_use {
			in_use_bytes += usize(span.npages) * vgc_page_size
		}
	}
	free_bytes := if in_use_bytes > usize(live) { in_use_bytes - usize(live) } else { usize(0) }
	// cx-private#1796: GCHeapUsage's Boehm meanings — unmapped_bytes is what the
	// pool trim returned to the OS (the cold, decommitted spans), never the
	// lifetime allocation count; bytes_since_gc is what the program allocated
	// since the last completed collection, never the collection count.
	// The per-thread un-flushed deltas (vgc_acct_alloc flushes every ~1 MB)
	// are counted too, so a reader sees what was allocated, not what was
	// flushed — a racy read of each slot, exact once the threads are quiet.
	mut pending := u64(0)
	for ci in 0 .. vgc_heap.ncaches {
		pending += unsafe { vgc_cache(ci).alloc_delta }
	}
	all := total_alloc + pending
	since := if all > vgc_heap.total_alloc_at_gc { all - vgc_heap.total_alloc_at_gc } else { u64(0) }
	return in_use_bytes, free_bytes, usize(live), usize(vgc_heap.pool_trimmed_bytes), usize(since)
}

fn vgc_memory_use() usize {
	mut total := usize(0)
	for i in 0 .. vgc_heap.narenas {
		total += vgc_heap.arenas[i].used
	}
	return total
}

// vgc_cache_layout answers where the cache records sit and where the fields a
// root word can name lie in one record (cx-home/v#51 diagnostic): a
// -d vgc_rootdiag line of kind caches gives the word's address, and this
// turns it into a slot and a field. A diagnostic read; it allocates its answer.
pub fn vgc_cache_layout() string {
	mut chunks := []string{}
	for ci in 0 .. C.vgc_ncache_chunks() {
		chunks << '0x${u64(usize(C.vgc_cache_chunk(ci))).hex()}'
	}
	return 'chunks=${chunks.join(',')} slots=${vgc_cache_chunk_slots} rec=${sizeof(VGC_Cache)} alloc=${__offsetof(VGC_Cache,
		alloc)} tiny=${__offsetof(VGC_Cache, tiny)} safe_regs=${__offsetof(VGC_Cache, safe_regs)} ncaches=${vgc_heap.ncaches}'
}

// the mask on the addresses vgc_orphan_holders keeps (no user-space address)
const vgc_oh_mask = usize(u64(0x5a5a000000000000))

// vgc_orphan_holders answers, for the allocated objects of one object size that
// no address in `known` points into (the caller's live set, sorted or not),
// every word that holds an address inside one: in the data segments, the cache
// slots, the suspend records, each registered thread's stack from the last
// collection's stack pointer to its top (offsets below the top, as
// -d vgc_rootdiag reports them; this function's own frames sit at the smallest
// offsets), the pins, and the scanned heap objects. The cx-home/v#51 evidence:
// which word keeps the span one run holds over the other. The addresses this
// function keeps are stored masked, so its own arrays hold none.
// A diagnostic read for a quiet heap (no collection running) on the calling
// thread; it allocates its answer.
pub fn vgc_orphan_holders(known []usize, size u32) string {
	mut ks := known.clone()
	ks.sort(a < b)
	mut orphans := []usize{}
	for i in 0 .. vgc_heap.nspans {
		span := unsafe { vgc_heap.allspans[i] }
		if span == unsafe { nil } || !span.in_use || span.elem_size != size
			|| span.alloc_bits == unsafe { nil } {
			continue
		}
		for idx in 0 .. span.nelems {
			if C.vgc_bitmap_get(span.alloc_bits, idx) == 0 {
				continue
			}
			o := span.base + usize(idx) * usize(span.elem_size)
			mut lo := 0
			mut hi := ks.len
			for lo < hi {
				mid := (lo + hi) / 2
				if ks[mid] < o {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			if lo < ks.len && ks[lo] < o + usize(size) {
				continue
			}
			if orphans.len < 16 {
				orphans << (o ^ vgc_oh_mask)
			}
		}
	}
	if orphans.len == 0 {
		return 'none'
	}
	mut out := []string{}
	for om in orphans {
		o := om ^ vgc_oh_mask
		mut hs := []string{}
		first := unsafe { *(&u8(voidptr(o))) }
		pay := unsafe { *(&u8(voidptr(o + 8))) }
		vgc_root_holders(mut hs, '', o, size)
		mut objs := []usize{}
		mut osz := []u32{}
		for i in 0 .. vgc_heap.nspans {
			span := unsafe { vgc_heap.allspans[i] }
			if span == unsafe { nil } || !span.in_use || span.noscan || span.elem_size == 0
				|| span.alloc_bits == unsafe { nil } {
				continue
			}
			for idx in 0 .. span.nelems {
				if C.vgc_bitmap_get(span.alloc_bits, idx) == 0 {
					continue
				}
				h := span.base + usize(idx) * usize(span.elem_size)
				n0 := hs.len
				vgc_holders_in(mut hs, if span.has_ptrmap { 'heap-p' } else { 'heap-c' }, h,
					h + usize(span.elem_size), h, o, size)
				if hs.len > n0 && objs.len < 4 {
					objs << (h ^ vgc_oh_mask)
					osz << span.elem_size
				}
			}
		}
		// one level up: who holds a heap object that holds the orphan
		for j, hm in objs {
			h := hm ^ vgc_oh_mask
			vgc_root_holders(mut hs, '0x${u64(h).hex()}<', h, osz[j])
		}
		out << '0x${u64(o).hex()} b0=${first} b8=${pay} [${vgc_orphan_state(o)}] by ${if hs.len == 0 { 'nothing' } else { hs.join(',') }}'
	}
	return out.join('; ')
}

// vgc_orphan_state answers why the sweep left the object at `o` allocated
// (cx-home/v#51): its mark bit from the last cycle (m=1: a root or an object
// reached it), the span's sweep stamp against the cycle (sg=), its in-flight
// claim (if=), whether it sits on a central list (oc=), its fill (ac=n/N),
// and the mutator slots whose cache holds the span (c=slot.class, or c=- when
// none) and whose tiny cursor sits in it (t=slot). A span the sweep skipped
// (cached, in flight, stamped this cycle) keeps every object it holds, marked
// or not.
fn vgc_orphan_state(o usize) string {
	sp := vgc_find_span(voidptr(o))
	if sp == unsafe { nil } {
		return 'no span'
	}
	span := &VGC_Span(sp)
	idx := u32((o - span.base) / usize(span.elem_size))
	m := if span.mark_bits != unsafe { nil } { C.vgc_bitmap_get(span.mark_bits, idx) } else { -1 }
	mut cached := []string{}
	mut tiny := []string{}
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { vgc_cache(i) }
		for sc in 0 .. 136 {
			if unsafe { c.alloc[sc] } == span {
				cached << '${i}.${sc}${if c.registered { '' } else { 'x' }}'
			}
		}
		if c.tiny != 0 && c.tiny >= span.base
			&& c.tiny < span.base + usize(span.npages) * vgc_page_size {
			tiny << '${i}'
		}
	}
	return 'm=${m} sg=${span.sweep_gen}/${vgc_heap.gc_cycle} if=${C.vgc_atomic_load_u32(&span.inflight)} oc=${span.on_central} ac=${span.alloc_count}/${span.nelems} c=${if cached.len == 0 { '-' } else { cached.join('+') }}${if tiny.len == 0 { '' } else { ' t=' + tiny.join('+') }}'
}

// vgc_root_holders appends the root words (data segments, cache slots, suspend
// records, registered stacks, pins) holding an address inside [o, o + size).
fn vgc_root_holders(mut hs []string, pre string, o usize, size u32) {
	for k in 0 .. vgc_nseg {
		if vgc_seg_lo[k] > 0 && vgc_seg_hi[k] > vgc_seg_lo[k] {
			vgc_holders_in(mut hs, '${pre}data${k}', vgc_seg_lo[k], vgc_seg_hi[k], vgc_seg_lo[k],
				o, size)
		}
	}
	mut left := vgc_heap.ncaches
	for ci in 0 .. C.vgc_ncache_chunks() {
		if left <= 0 {
			break
		}
		n := if left < vgc_cache_chunk_slots { left } else { vgc_cache_chunk_slots }
		base := usize(C.vgc_cache_chunk(ci))
		vgc_holders_in(mut hs, '${pre}caches', base, base + usize(n) * usize(sizeof(VGC_Cache)),
			base, o, size)
		left -= n
	}
	for ci in 0 .. C.vgc_ncache_chunks() {
		mut slo := usize(0)
		mut shi := usize(0)
		if C.vgc_susp_chunk_bounds(ci, &slo, &shi) != 0 {
			vgc_holders_in(mut hs, '${pre}suspend', slo, shi, slo, o, size)
		}
	}
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { vgc_cache(i) }
		if !c.registered || c.stack_lo == 0 || c.stack_hi <= c.stack_lo {
			continue
		}
		vgc_holders_in(mut hs, '${pre}stack${i}', c.stack_lo, c.stack_hi, c.stack_hi, o, size)
	}
	for k in 0 .. vgc_npins {
		p := usize(unsafe { vgc_pins[k] })
		if p >= o && p < o + usize(size) {
			hs << '${pre}pin${k}'
		}
	}
}

// vgc_holders_in appends one "kind+offset=value-offset" entry per word of
// [lo, hi) that holds an address inside [o, o + size); offsets are from `rel`
// (a range's start, or a stack's top).
fn vgc_holders_in(mut hs []string, kind string, lo usize, hi usize, rel usize, o usize, size u32) {
	mut a := (lo + sizeof(usize) - 1) & ~(usize(sizeof(usize)) - 1)
	for a + sizeof(usize) <= hi {
		v := unsafe { *(&usize(voidptr(a))) }
		if v >= o && v < o + usize(size) && hs.len < 24 {
			off := if rel > a { i64(rel - a) } else { i64(a - rel) }
			hs << if kind.starts_with('heap') {
				'${kind}${vgc_find_span(voidptr(a)).elem_size}+${off}@0x${u64(a).hex()}=+${v - o}'
			} else {
				'${kind}+${off}@0x${u64(a).hex()}=+${v - o}'
			}
		}
		a += sizeof(usize)
	}
}
