// vgc_gc_d_vgc.c.v - V Garbage Collector: Mark, sweep, and orchestration
// Translated from Go's runtime GC (mgc.go, mgcmark.go, mgcsweep.go, mgcwork.go, mgcpacer.go)
// Concurrent tri-color mark-and-sweep with parallel marking.

@[has_globals]
module builtin

// ============================================================
// GC Orchestration (translated from Go's runtime.gcStart, gcMarkDone, gcMarkTermination)
// ============================================================

// vgc_gc_start triggers a garbage collection cycle.
// Translated from Go's gcStart() in mgc.go.
// Flow: sweep termination (STW) -> full STW mark -> sweep -> resume.
// Invoked via the vgc_run_gc_spilled trampoline (vgc_platform.h), which has
// already recorded THIS thread's stack range with callee-saved registers
// spilled — so vgc_gc_start must NOT re-record the collector's own range.
@[export: 'vgc_gc_start']
fn vgc_gc_start() {
	$if vgc_concurrent ? {
		// Concurrent-mark collector: mark while mutators run, with two brief STW
		// points. Gated by `-d vgc_concurrent`; the default build falls through to
		// the proven full-STW body below (byte-identical, diff-able for bisection).
		vgc_gc_start_concurrent()
		return
	}
	// Only one GC at a time
	mut expected := vgc_phase_off
	if !C.vgc_atomic_cas_u32(&vgc_heap.gc_phase, &expected, vgc_phase_mark) {
		return
	}

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
	// susp[i] records which slots THIS cycle mach-suspended, so resume targets exactly
	// them. Default path: every other registered mutator. Cooperative path: only the
	// stragglers that did not self-park. Used by both branches + the resume loop.
	mut susp := [vgc_max_threads]bool{}
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
		$if vgc_schedfuzz ? {
			// Widen the post-flag / pre-suspend window (site 1): the interval in
			// which a mutator can observe the flag, begin parking, or a dying
			// worker can begin its spawn-root remove, before the collector reaches
			// the suspend loop. Biases the exact race the forensics implicated.
			vgc_fuzz_pause(1)
		}
		mut want := u32(0)
		for i in 0 .. vgc_heap.ncaches {
			c := unsafe { &vgc_heap.caches[i] }
			if c.registered && i != self_idx && c.mach_port != 0 {
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
			mut spins := 0
			for C.vgc_atomic_load_u32(&vgc_heap.gc_stopped_count) < want && spins < 200000 {
				C.vgc_atomic_fence()
				spins++
			}
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
		for i in 0 .. vgc_heap.ncaches {
			c := unsafe { &vgc_heap.caches[i] }
			C.vgc_trace(6, i, if c.registered { u64(1) } else { u64(0) }, u64(c.mach_port))
			if c.registered && i != self_idx && c.mach_port != 0
				&& (C.vgc_atomic_load_u32(&vgc_heap.caches[i].stopped) == 0
				|| c.park_seq != C.vgc_atomic_load_u32(&vgc_heap.gc_stop_seq)) {
				// stopped==1 counts ONLY with a matching park_seq: a stale park from
				// the previous cycle is a WAKING thread that will run through this
				// GC — suspend it like any straggler. susp[i] reflects the ACK, not
				// the attempt: an un-acked target is a gone thread (safe to skip),
				// never a running mutator (the suspend waits for live targets).
				susp[i] = C.vgc_suspend_thread(c.mach_port) != 0
				C.vgc_trace(7, i, u64(c.mach_port), 0)
			}
		}
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
			c := unsafe { &vgc_heap.caches[i] }
			reg := if c.registered { u64(1) } else { u64(0) }
			C.vgc_trace(6, i, reg, u64(c.mach_port)) // SUSP? (decision inputs for EVERY slot)
			if c.registered && i != self_idx && c.mach_port != 0 {
				// susp[i] reflects the ACK (see the cooperative branch above).
				susp[i] = C.vgc_suspend_thread(c.mach_port) != 0
				C.vgc_trace(7, i, u64(c.mach_port), 0) // SUSP! (actually suspended)
			}
		}
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
			c := unsafe { &vgc_heap.caches[i] }
			if c.registered && i != self_idx && c.mach_port != 0 {
				parked_now := C.vgc_atomic_load_u32(&vgc_heap.caches[i].stopped) != 0
					&& c.park_seq == C.vgc_atomic_load_u32(&vgc_heap.gc_stop_seq)
				if !parked_now && !susp[i] {
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

	// Clear mark bits on all spans (prepare for new cycle)
	vgc_clear_mark_bits()
	vgc_watch_snapshot(0) // STAGE 0: post-clear (expect found+in_use+alloc, mark=0)

	// Scan each suspended thread's roots: refresh its stack range from the
	// actual suspended SP and shade its register-resident roots (the exact roots
	// a stack-only scan misses; validated in bench/parallel-alloc/stw_root_scan.c).
	vgc_scan_suspended_roots(self_idx)
	vgc_watch_snapshot(1) // STAGE 1: post suspended-thread reg/stack roots (main's reg holds c)
	$if vgc_rangedump ? {
		// #58 diagnostic: dump EVERY registered thread's post-refresh scan range so a
		// rootfind EXTERNAL holder can be correlated — is it below stack_lo (size under-
		// estimated), above stack_hi (base wrong), or in no range at all (unregistered peer)?
		for di in 0 .. vgc_heap.ncaches {
			dc := unsafe { &vgc_heap.caches[di] }
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
			sc := unsafe { &vgc_heap.caches[si] }
			if sc.registered && si < 64 {
				vgc_spchk_lo[si] = sc.stack_lo
				vgc_spchk_hi[si] = sc.stack_hi
				vgc_spchk_cyc[si] = u64(vgc_heap.gc_cycle)
				vgc_spchk_parked[si] = u64(C.vgc_atomic_load_u32(&vgc_heap.caches[si].stopped))
			}
		}
	}

	// === Phase 2: Mark (parallel) ===
	// Enable write barrier (for concurrent correctness)
	C.vgc_atomic_store_u32(&vgc_heap.wb_enabled, 1)

	// NOTE: the collector's own stack range was already recorded (with
	// registers spilled) by the vgc_run_gc_spilled trampoline before this
	// function was entered. Do NOT call vgc_refresh_stack_range() here — that
	// would overwrite the range with a higher SP and drop the spilled regs.

	// Scan roots: stacks + globals (conservative scanning)
	vgc_mark_roots()
	vgc_watch_snapshot(2) // STAGE 2: post stack roots

	// Shade in-flight spawn-argument structs. These are live (a freshly created
	// thread is about to read them) but unreachable from any scanned stack during
	// the create->start handoff, because the child is not yet registered. Reading
	// the array without the lock is safe here: the world is stopped, so no mutator
	// can be mid add/remove except one frozen holding the lock, and an entry is
	// only counted after its slot is written. (See vgc_spawn_roots.)
	for i in 0 .. vgc_nspawn_roots {
		root := usize(vgc_spawn_roots[i])
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

	// FULL stop-the-world mark+sweep: the world stays stopped from here through
	// the end of sweep. The previous design resumed mutators here and marked
	// concurrently, but objects allocated DURING the concurrent mark were not
	// alloc-blacked and stack-local pointer writes carry no write barrier, so a
	// freshly-allocated-but-live object (e.g. `last` in a tight alloc loop) was
	// swept -> use-after-free. Keeping the world stopped through sweep removes
	// that entire unsound-concurrency window. (Concurrency is a later perf
	// optimization that must come with alloc-black + a correct barrier.)

	// Parallel mark: drain the work queue (workers only; mutators are stopped)
	vgc_parallel_mark()
	vgc_watch_snapshot(4) // STAGE 4: post parallel-mark drain

	// === Phase 3: Mark Termination (brief STW) ===
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_mark_term)

	// Final drain of work queue
	vgc_drain_mark_work()
	vgc_watch_snapshot(5) // STAGE 5: post final drain (mark term)

	// Disable write barrier
	C.vgc_atomic_store_u32(&vgc_heap.wb_enabled, 0)

	$if vgc_remark ? {
		// #58 RE-MARK DETERMINISM CHECK (world still stopped, post-mark, pre-sweep).
		// Additive from the SAME frozen roots (idempotent -> sweep stays safe). If
		// v2>v1 the first mark was INCOMPLETE from roots (0xd7a2). Established RESULT:
		// v2==v1 every GC -> mark is complete + deterministic from roots.
		v1 := vgc_count_marked_victimclass()
		vgc_mark_roots()
		for i in 0 .. vgc_nspawn_roots {
			vgc_shade_spawn_root(usize(vgc_spawn_roots[i]))
		}
		vgc_drain_mark_work()
		v2 := vgc_count_marked_victimclass()
		if v2 != v1 {
			C.vgc_say(0xd7a2, u64(v1))
			C.vgc_say(0xd7a3, u64(v2))
		}
	}
	$if vgc_remark_ns ? {
		// #58 NOSCAN-HOLDER DISCRIMINATOR (world stopped, post-mark, pre-sweep).
		// drain_mark_work SKIPS noscan objects (they "contain no pointers"), so a
		// live pointer stored in a MARKED noscan object is never traced -> its
		// referent is swept-while-live. Test: conservatively scan every MARKED
		// noscan object's words (shading referents), drain, and recount victim-class
		// marks. v2>v1 (0xd7b2 v1, 0xd7b3 v2) => a marked NOSCAN object holds a live
		// pointer to a victim-class object the trace missed = noscan-misclassification
		// (a pointer-bearing struct allocated via malloc_noscan). v2==v1 => not a
		// noscan holder either -> the reference is a dangling interpreter alias.
		// LIGHT aggregate (the per-word find_span attribution masked the race —
		// heavy probes shift the window; only this light form reproduces): scan
		// every MARKED noscan object's words (shade+enqueue), drain, recount
		// victim-class marks. w2>w1 => a marked noscan object held a live pointer
		// the trace missed = noscan-misclassification. This is the CONFIRMED
		// mechanism + the regression oracle for the fix (fix => w2==w1 always).
		w1 := vgc_count_marked_victimclass()
		for i in 0 .. vgc_heap.nspans {
			span := unsafe { vgc_heap.allspans[i] }
			if span == unsafe { nil } || !span.in_use || !span.noscan
				|| span.mark_bits == unsafe { nil } || span.elem_size == 0 {
				continue
			}
			for oi in 0 .. span.nelems {
				if C.vgc_bitmap_get(span.mark_bits, oi) == 0 {
					continue
				}
				ob := span.base + usize(oi) * usize(span.elem_size)
				vgc_scan_range(ob, ob + usize(span.elem_size))
			}
		}
		vgc_drain_mark_work()
		w2 := vgc_count_marked_victimclass()
		if w2 != w1 {
			C.vgc_say(0xd7b2, u64(w1))
			C.vgc_say(0xd7b3, u64(w2))
		}
	}

	// Compute live bytes from mark bits
	marked := vgc_count_marked()
	C.vgc_atomic_store_u64(&vgc_heap.heap_marked, marked)
	// Reset heap_live to match what we actually found alive. The per-thread
	// live_delta/alloc_delta (un-flushed accounting) are now stale — `marked` is
	// the true live set — so flush each thread's total-alloc stat and zero both
	// deltas. Safe: the world is stopped, so no mutator is mid-update.
	for ci in 0 .. vgc_heap.ncaches {
		unsafe {
			vgc_heap.total_alloc += vgc_heap.caches[ci].alloc_delta
			vgc_heap.caches[ci].alloc_delta = 0
			vgc_heap.caches[ci].live_delta = 0
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
	if vgc_gctrace != 0 {
		// VGC_GCTRACE=1 per-cycle pacing trace (GODEBUG=gctrace analog). Emitted
		// under STW right after the trigger recompute, so every field is a
		// consistent snapshot: cycle, marked (true live set), the recomputed base
		// goal (pre thread-multiplier), arena/span pressure, live mutators.
		// Env-gated (one integer test per cycle when off).
		C.vgc_gctrace_line(u64(vgc_heap.gc_cycle),
			C.vgc_atomic_load_u64(&vgc_heap.heap_marked),
			C.vgc_atomic_load_u64(&vgc_heap.next_gc), u64(vgc_heap.narenas),
			u64(vgc_heap.nspans), u64(C.vgc_atomic_load_u32(&vgc_heap.live_threads)))
	}
	vgc_heap.gc_cycle++

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
	}

	// Resume the world: mark + sweep are complete, every live object survived, and
	// gc_cycle/trigger are already advanced (above) so resumed mutators stamp spans
	// with the correct cycle. Resume exactly the slots THIS cycle mach-suspended
	// (susp[]); cooperative parkers are released via gc_stop_flag above.
	C.vgc_atomic_fence()
	for i in 0 .. vgc_heap.ncaches {
		if susp[i] {
			c := unsafe { &vgc_heap.caches[i] }
			C.vgc_resume_thread(c.mach_port)
			C.vgc_trace(11, i, u64(c.mach_port), 0) // RESUME
		}
	}
	C.vgc_mutex_unlock(&vgc_heap.cache_lock) // release the registration gate

	C.vgc_trace(12, self_idx, u64(vgc_heap.gc_cycle), 0) // GC_END
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_off)
}

// ============================================================
// Concurrent mark (vgc_concurrent) — mark while mutators run.
// ============================================================

// Take every allocator lock (while its holders are still RUNNING, so none is
// frozen mid-critical-section), then mach-suspend every other registered
// mutator. Mirrors the STW collector's enter sequence; used for BOTH
// concurrent-mark STW windows (start and termination). The write barrier never
// touches an allocator lock or the work queue, so at the termination window no
// mutator can be frozen holding one of these (closing the frozen-owner class).
@[markused]
fn vgc_cm_stw_enter(self_idx int) {
	C.vgc_mutex_lock(&vgc_heap.free_spans_lock)
	C.vgc_mutex_lock(&vgc_heap.cache_lock)
	C.vgc_mutex_lock(&vgc_heap.lock)
	for i in 0 .. 136 {
		C.vgc_mutex_lock(&vgc_heap.central[i].lock)
	}
	C.vgc_mutex_lock(&vgc_spawn_root_lock) // dying-thread remove vs spawn-root scan (see vgc_gc_start)
	C.vgc_atomic_store_u32(&vgc_heap.gc_stop_flag, 0) // OS-suspend, not cooperative
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { &vgc_heap.caches[i] }
		if c.registered && i != self_idx && c.mach_port != 0 {
			_ = C.vgc_suspend_thread(c.mach_port)
		}
	}
	// The work queue is collector-exclusive (mutators never enqueue — the write barrier
	// only dirties spans, and GC-assist is not wired; see vgc_maybe_gc), so no holder can
	// be frozen mid-op; a plain reset suffices.
	C.vgc_atomic_store_u32(&vgc_heap.work_lock, 0)
}

// Release every allocator lock (reverse order) and resume every other mutator.
@[markused]
fn vgc_cm_stw_exit(self_idx int) {
	C.vgc_mutex_unlock(&vgc_spawn_root_lock)
	for i in 0 .. 136 {
		C.vgc_mutex_unlock(&vgc_heap.central[i].lock)
	}
	C.vgc_mutex_unlock(&vgc_heap.lock)
	C.vgc_mutex_unlock(&vgc_heap.free_spans_lock)
	C.vgc_atomic_fence()
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { &vgc_heap.caches[i] }
		if c.registered && i != self_idx && c.mach_port != 0 {
			C.vgc_resume_thread(c.mach_port)
		}
	}
	C.vgc_mutex_unlock(&vgc_heap.cache_lock) // release the registration gate last
}

// Re-scan every span the write barrier dirtied during the concurrent middle.
// Conservatively scans each dirtied scannable span's allocated objects, shading
// their CURRENT referents — so any white object that a mutator stored into an
// already-black object survives (the "hide a white behind a black" hazard).
// Runs under STW (mark-termination), so the allspans walk and per-object scans
// are race-free. Clears each dirty flag as it goes.
@[markused]
fn vgc_rescan_dirty_spans() {
	$if vgc_cm_nobarrier ? {
		// TEETH KNOB (testing only): skip the dirty-span re-scan, disabling the write
		// barrier's effect. A sound concurrent-mark build must NEVER set this; it exists
		// only so the soundness gate (cm_stress.v) can demonstrate it reproduces live
		// reclamation without the barrier. See bench/parallel-alloc/CONCURRENT-MARK-DESIGN.md.
		return
	}
	for i in 0 .. vgc_heap.nspans {
		span := unsafe { vgc_heap.allspans[i] }
		if span == unsafe { nil } || !span.in_use || span.noscan {
			continue
		}
		if C.vgc_atomic_load_u32(&span.dirty) == 0 {
			continue
		}
		if span.alloc_bits != unsafe { nil } {
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
						obj_addr := span.base + usize(idx) * usize(span.elem_size)
						vgc_scan_range(obj_addr, obj_addr + usize(span.elem_size))
					}
				}
			}
		}
		unsafe {
			C.vgc_atomic_store_u32(&(&VGC_Span(span)).dirty, 0)
		}
	}
}

// The concurrent-mark cycle: two brief STW points around a concurrent mark.
//   (1) STW start: clear marks, scan roots, enable barrier + alloc-black, resume.
//   (2) concurrent mark: drain the grey set while mutators run (barrier dirties
//       mutated spans; new allocations are alloc-black).
//   (3) STW mark-termination: re-scan dirtied roots + dirty spans, final drain,
//       disable barrier, sweep, resume.
// Entered via the vgc_run_gc_spilled trampoline (like vgc_gc_start), so THIS
// thread's stack range + spilled registers are already recorded; the collector
// stays parked in here across the concurrent middle, so that recorded range still
// covers the triggering mutator's frames at termination (do NOT refresh self).
@[markused]
fn vgc_gc_start_concurrent() {
	mut expected := vgc_phase_off
	if !C.vgc_atomic_cas_u32(&vgc_heap.gc_phase, &expected, vgc_phase_mark) {
		return // a cycle is already in flight
	}
	self_idx := C.vgc_get_cache_idx()

	// ===== STW START =====
	vgc_cm_stw_enter(self_idx)
	vgc_sweep_finish() // finish any lazy sweep from the previous cycle
	vgc_clear_mark_bits()
	vgc_scan_suspended_roots(self_idx) // refresh other stacks from suspended SP + reg roots
	// Enable the barrier and alloc-black BEFORE resuming: the instant a mutator
	// runs again, its pointer stores dirty their span and its allocations are
	// alloc-blacked. gc_phase is already vgc_phase_mark (from the CAS above), which
	// is what vgc_alloc_black_hook tests.
	C.vgc_atomic_store_u32(&vgc_heap.wb_enabled, 1)
	vgc_mark_roots() // globals/BSS + every thread stack (snapshot)
	for i in 0 .. vgc_nspawn_roots {
		vgc_shade_spawn_root(usize(vgc_spawn_roots[i]))
	}
	vgc_cm_stw_exit(self_idx) // RESUME the world — mark now runs concurrently

	// ===== CONCURRENT MARK (world running) =====
	vgc_drain_mark_work() // collector-exclusive queue; mutators only dirty spans

	// ===== STW MARK-TERMINATION =====
	vgc_cm_stw_enter(self_idx)
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_mark_term)
	vgc_scan_suspended_roots(self_idx) // re-scan dirtied roots (stacks moved)
	vgc_mark_roots()
	for i in 0 .. vgc_nspawn_roots {
		vgc_shade_spawn_root(usize(vgc_spawn_roots[i]))
	}
	vgc_rescan_dirty_spans() // re-scan everything the barrier dirtied
	vgc_drain_mark_work() // final drain of the grey set
	C.vgc_atomic_store_u32(&vgc_heap.wb_enabled, 0)

	// Compute live bytes from mark bits; rebase heap_live (same as the STW path).
	marked := vgc_count_marked()
	C.vgc_atomic_store_u64(&vgc_heap.heap_marked, marked)
	for ci in 0 .. vgc_heap.ncaches {
		unsafe {
			vgc_heap.total_alloc += vgc_heap.caches[ci].alloc_delta
			vgc_heap.caches[ci].alloc_delta = 0
			vgc_heap.caches[ci].live_delta = 0
		}
	}
	C.vgc_atomic_store_u64(&vgc_heap.heap_live, marked)

	// Sweep (STW) — no span is freed during the concurrent middle, so sweeping
	// here is identical to the STW collector.
	vgc_heap.sweep_gen++
	C.vgc_atomic_store_u32(&vgc_heap.sweep_done, 0)
	vgc_heap.sweep_idx = 0
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_sweep)
	vgc_do_sweep()
	vgc_fixup_caches()
	vgc_cm_stw_exit(self_idx)

	vgc_update_trigger()
	vgc_heap.gc_cycle++
	C.vgc_atomic_store_u32(&vgc_heap.gc_phase, vgc_phase_off)
}

// Scan the roots of every suspended mutator: refresh its stack range from its
// real (suspended) SP and shade its register-resident roots. Mach
// thread_get_state yields both, so register roots come for free — closing the
// stack-only-scan gap that dropped live values. (stw_root_scan.c prototype.)
fn vgc_scan_suspended_roots(self_idx int) {
	for i in 0 .. vgc_heap.ncaches {
		c := unsafe { &vgc_heap.caches[i] }
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
			if C.vgc_atomic_load_u32(&vgc_heap.caches[i].stopped) != 0
				&& c.park_seq == C.vgc_atomic_load_u32(&vgc_heap.gc_stop_seq) {
				continue
			}
		}
		mut sp := usize(0)
		// 31 GP (x0–x28 + fp + lr) + 64 NEON lanes (v0–v31 × 2) = 95 conservative
		// root candidates per suspended thread (arm64; x86_64 fills only the first 15).
		mut regs := [95]usize{}
		n := C.vgc_thread_regs(c.mach_port, &sp, &regs[0], 95)
		C.vgc_trace(8, i, u64(sp), u64(n)) // SCAN (sp + reg count actually captured)
		if n > 0 && sp != 0 {
			vgc_refresh_stack_range_for_sp(i, sp) // [sp, stack_base]
			for k in 0 .. n {
				vgc_shade(regs[k]) // register-resident roots
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
	for i in 0 .. vgc_heap.nspans {
		span := unsafe { vgc_heap.allspans[i] }
		if span == unsafe { nil } || !span.in_use {
			continue
		}
		if span.mark_bits != unsafe { nil } {
			bitmap_size := (span.nelems + 7) / 8
			unsafe { C.memset(span.mark_bits, 0, bitmap_size) }
		}
	}
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
		c := unsafe { &vgc_heap.caches[i] }
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
		mut c := unsafe { &vgc_heap.caches[i] }
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
	mut seg_lo := [8]usize{}
	mut seg_hi := [8]usize{}
	nseg := C.vgc_data_segments(&seg_lo[0], &seg_hi[0], 8)
	// Scan the WHOLE data segment, including the collector's own `vgc_heap` struct.
	// It is tempting to skip vgc_heap (it is large and is "just" collector metadata),
	// but doing so intermittently reclaims live data: vgc_heap's per-thread caches
	// hold pointers (the tiny-allocator cursor / the in-flight mcache spans' object
	// memory) that conservatively root objects the stack+register scan does not fully
	// cover during thread create/exit churn. Excluding it removes that protection and
	// G-CHURN fails ~1-in-3 with reclaimed anchor nodes (verified by isolation). The
	// scan is cheap now that span reuse is fixed (vgc_heap stays small and bounded),
	// so correctness wins: scan it all.
	$if vgc_verify ? {
		// DEBUG: dump the data-segment ranges once so we can check whether a given
		// __global's address is actually covered by the conservative root scan.
		if !vgc_segdump_done {
			vgc_segdump_done = true
			C.vgc_say(0x5e60, u64(nseg)) // SEG count
			for k in 0 .. nseg {
				C.vgc_say(0x5e61, u64(seg_lo[k])) // SEG lo
				C.vgc_say(0x5e62, u64(seg_hi[k])) // SEG hi
			}
		}
	}
	for k in 0 .. nseg {
		if seg_lo[k] > 0 && seg_hi[k] > seg_lo[k] {
			vgc_scan_range(seg_lo[k], seg_hi[k])
		}
	}

	// Scan each registered thread's stack
	for i in 0 .. vgc_heap.ncaches {
		cache := unsafe { &vgc_heap.caches[i] }
		if !cache.registered {
			continue
		}
		if cache.stack_lo > 0 && cache.stack_hi > 0 && cache.stack_hi > cache.stack_lo {
			vgc_scan_range(cache.stack_lo, cache.stack_hi)
			// DIAGNOSTIC (root-scan-miss localizer): does THIS thread's stack hold
			// a pointer to the watched object? Bounded to the stack ranges only.
			if vgc_watch_addr != 0 {
				vgc_watch_scan_range(cache.stack_lo, cache.stack_hi, i)
			}
		}
	}

	// Shade pinned objects — cgo-safe explicit roots (see vgc_pin). A live object
	// reachable only from non-GC (FFI/C) memory is invisible to the precise scan
	// above; pinning makes it a root so it (and its transitive referents) survive.
	// Lock-free read under STW: frozen mutators cannot mutate the set, and unpin's
	// publish-before-shrink keeps every live pin visible (see vgc_pin/vgc_unpin).
	np := vgc_npins
	for k in 0 .. np {
		vgc_shade(usize(unsafe { vgc_pins[k] }))
	}
}

// Scan a memory range conservatively, looking for pointers into the GC heap.
// Each word-aligned value that looks like a heap pointer is treated as a root.
// Translated from Go's scanblock() with conservative pointer finding.
fn vgc_scan_range(lo usize, hi usize) {
	// Align to word boundaries
	start := (lo + sizeof(usize) - 1) & ~(usize(sizeof(usize)) - 1)
	mut addr := start
	for addr + sizeof(usize) <= hi {
		val := unsafe { *(&usize(voidptr(addr))) }
		if val != 0 {
			vgc_shade(val)
		}
		addr += sizeof(usize)
	}
}

// Shade marks an object grey (discovered but not yet scanned).
// Translated from Go's shade() in mgcmark.go.
fn vgc_shade(addr usize) {
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
	// Mark it (grey -> will be scanned)
	if span.mark_bits != unsafe { nil } {
		if C.vgc_bitmap_test_and_set(span.mark_bits, obj_idx) == 0 {
			// Newly marked - add to work queue for scanning (only if it may contain pointers)
			mut scanit := !span.noscan
			$if vgc_scanall ? {
				scanit = true // #58 diagnostic: conservatively scan ALL noscan objects
			}
			$if vgc_scansmall ? {
				// #58 FIX: also conservatively scan SMALL noscan objects. V codegen marks
				// some small pointer-bearing structs noscan (misclassification); their
				// referents (worker bindings keys-arrays) then go untraced and swept-while-
				// live. Confirmed by the noscan-holder discriminator: conservatively
				// scanning noscan objects reaches the missed victim. Bounded to <=64B so
				// large noscan buffers (strings/arrays, genuinely pointer-free) stay
				// skipped => negligible perf. Conservative scan only OVER-retains, never UAF.
				if span.noscan && span.elem_size <= u32(64) {
					scanit = true
				}
			}
			if scanit {
				obj_addr := span.base + usize(obj_idx) * usize(span.elem_size)
				vgc_work_put(obj_addr)
			}
		}
	}
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
	vgc_scan_range(obj_base, obj_base + usize(span.elem_size))
}

// Parallel mark using OS threads.
// Translated from Go's gcDrain() with multiple workers.
fn vgc_parallel_mark() {
	// Single-threaded mark for the minimal STW collector: spawning mark-worker
	// threads during a collection would have them hit the registration barrier
	// (gc_phase != off) and deadlock, and the work-queue lock-stealing under STW
	// assumes a single marker. Collection is rare (Perceus front line front-loads
	// frees), so single-threaded mark is acceptable; parallel mark is a later
	// optimization that must reintroduce a GC-worker exemption from the barrier.
	mut nworkers := 1
	vgc_heap.gc_nworkers = nworkers
	C.vgc_atomic_store_u32(&vgc_heap.gc_workers_done, 0)

	if nworkers <= 1 {
		vgc_drain_mark_work()
		return
	}

	// Start helper workers and let the current GC thread participate as well.
	for _ in 1 .. nworkers {
		C.vgc_start_thread(vgc_mark_worker)
	}
	vgc_drain_mark_work()
	C.vgc_atomic_add_u32(&vgc_heap.gc_workers_done, 1)

	// Wait for all workers to finish
	for C.vgc_atomic_load_u32(&vgc_heap.gc_workers_done) < u32(nworkers) {
		C.vgc_atomic_fence()
	}
}

// Mark worker function - runs in a spawned thread.
// Translated from Go's gcDrain() loop.
fn vgc_mark_worker() {
	vgc_ensure_registered()
	vgc_drain_mark_work()
	C.vgc_atomic_add_u32(&vgc_heap.gc_workers_done, 1)
}

// Drain the mark work queue - scan grey objects and mark their referents.
// Uses precise pointer maps when available (from vgc_malloc_typed),
// falls back to conservative scanning otherwise.
fn vgc_drain_mark_work() {
	for {
		obj_addr := vgc_work_get()
		if obj_addr == 0 {
			break
		}
		span := vgc_find_span(voidptr(obj_addr))
		if span == unsafe { nil } {
			continue
		}
		if span.noscan {
			$if vgc_scanall ? {
				// diagnostic: scan every enqueued noscan object (no size gate)
			} $else {
				$if vgc_scansmall ? {
					if span.elem_size > u32(64) {
						continue
					}
				} $else {
					continue // noscan objects contain no pointers (codegen-reliable)
				}
			}
		}
		// Scan every word conservatively. NOTE: precise per-span ptrmap scanning is
		// UNSOUND here and was removed — a span serves one size CLASS, but real
		// workloads pack many different TYPES (and conservative ptrmap==0 allocations)
		// into the same size class. The span records only the FIRST typed alloc's
		// ptrmap (vgc_malloc_typed_opts "first typed allocation wins") and applies it
		// to every object, so any object whose real pointer layout differs has live
		// child pointers skipped -> reclaimed-while-reachable (observed as corrupted
		// results under a deep alloc-heavy serial fold). Conservative scanning finds
		// every pointer (may over-retain, never under-retains); the backstop runs
		// rarely behind the Perceus front line, so the cost is negligible.
		obj_size := usize(span.elem_size)
		vgc_scan_range(obj_addr, obj_addr + obj_size)
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
			vgc_shade(val)
		}
		// Clear this bit and continue
		mask &= mask - 1
	}
}

// ============================================================
// Work queue (translated from Go's mgcwork.go)
// ============================================================

@[inline]
fn vgc_can_use_work_fastpath() bool {
	return vgc_heap.ncaches <= 1 && vgc_heap.gc_nworkers <= 1
}

// Add a pointer to the mark work queue
fn vgc_work_put(addr usize) {
	if vgc_can_use_work_fastpath() {
		mut buf := vgc_heap.work_full
		if buf == unsafe { nil } || buf.nobj >= 256 {
			mut new_buf := vgc_heap.work_empty
			if new_buf != unsafe { nil } {
				unsafe {
					vgc_heap.work_empty = new_buf.next
				}
			} else {
				new_buf = unsafe { &VGC_WorkBuf(C.vgc_os_alloc(usize(sizeof(VGC_WorkBuf)))) }
				if new_buf == unsafe { nil } {
					$if vgc_workdrop ? {
						vgc_workdrop_count++ // #58: grey object SILENTLY DROPPED (os_alloc nil)
						C.vgc_say(0xd709, u64(addr))
					}
					return
				}
			}
			unsafe {
				new_buf.nobj = 0
				new_buf.next = vgc_heap.work_full
				vgc_heap.work_full = new_buf
			}
			buf = new_buf
		}
		unsafe {
			buf.obj[buf.nobj] = addr
			buf.nobj++
		}
		return
	}

	C.vgc_mutex_lock(&vgc_heap.work_lock)

	// Get or create a work buffer
	mut buf := vgc_heap.work_full
	if buf == unsafe { nil } || buf.nobj >= 256 {
		// Need a new buffer
		mut new_buf := vgc_heap.work_empty
		if new_buf != unsafe { nil } {
			unsafe {
				vgc_heap.work_empty = new_buf.next
			}
		} else {
			new_buf = unsafe { &VGC_WorkBuf(C.vgc_os_alloc(usize(sizeof(VGC_WorkBuf)))) }
			if new_buf == unsafe { nil } {
				$if vgc_workdrop ? {
					vgc_workdrop_count++ // #58: grey object SILENTLY DROPPED (os_alloc nil, slowpath)
					C.vgc_say(0xd709, u64(addr))
				}
				C.vgc_mutex_unlock(&vgc_heap.work_lock)
				return
			}
		}
		unsafe {
			new_buf.nobj = 0
			new_buf.next = vgc_heap.work_full
			vgc_heap.work_full = new_buf
		}
		buf = new_buf
	}

	unsafe {
		buf.obj[buf.nobj] = addr
		buf.nobj++
	}
	C.vgc_mutex_unlock(&vgc_heap.work_lock)
}

// Get a pointer from the mark work queue
fn vgc_work_get() usize {
	if vgc_can_use_work_fastpath() {
		mut buf := vgc_heap.work_full
		if buf == unsafe { nil } || buf.nobj == 0 {
			return 0
		}
		unsafe {
			buf.nobj--
			addr := buf.obj[buf.nobj]
			if buf.nobj == 0 {
				vgc_heap.work_full = buf.next
				buf.next = vgc_heap.work_empty
				vgc_heap.work_empty = buf
			}
			return addr
		}
	}

	C.vgc_mutex_lock(&vgc_heap.work_lock)

	mut buf := vgc_heap.work_full
	if buf == unsafe { nil } || buf.nobj == 0 {
		C.vgc_mutex_unlock(&vgc_heap.work_lock)
		return 0
	}

	unsafe {
		buf.nobj--
		addr := buf.obj[buf.nobj]

		// If buffer is empty, move to empty list
		if buf.nobj == 0 {
			vgc_heap.work_full = buf.next
			buf.next = vgc_heap.work_empty
			vgc_heap.work_empty = buf
		}

		C.vgc_mutex_unlock(&vgc_heap.work_lock)
		return addr
	}
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
	vgc_shade(usize(new_val))
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
@[export: 'vgc_wb_store']
fn vgc_wb_store(obj voidptr) {
	$if vgc_concurrent ? {
		if C.vgc_atomic_load_u32(&vgc_heap.wb_enabled) == 0 {
			return
		}
		if obj == unsafe { nil } {
			return
		}
		span := vgc_find_span(obj)
		if span != unsafe { nil } && span.in_use && !span.noscan {
			unsafe {
				C.vgc_atomic_store_u32(&(&VGC_Span(span)).dirty, 1)
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
		obj_addr := vgc_work_get()
		if obj_addr == 0 {
			break
		}
		span := vgc_find_span(voidptr(obj_addr))
		if span == unsafe { nil } || span.noscan {
			continue
		}
		obj_size := usize(span.elem_size)
		vgc_scan_range(obj_addr, obj_addr + obj_size)
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
									u64(obj_addr), u64(span.elem_size), u64(addr - obj_addr),
									u64(tspan.base + usize(tidx) * usize(tspan.elem_size)),
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
							c := unsafe { &vgc_heap.caches[i] }
							if c.registered && c.stack_lo > 0 && c.stack_hi > c.stack_lo
								&& addr >= c.stack_lo && addr < c.stack_hi {
								in_stack = 1
								break
							}
						}
						if vgc_rootfind_count < 80 {
							C.vgc_rootfind_report(u64(addr), in_stack,
								u64(span.base + usize(tidx) * usize(span.elem_size)),
								u64(span.elem_size), u64(kind))
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
			cc := unsafe { &vgc_heap.caches[ci] }
			if !cc.registered || ci == swp_self || cc.mach_port == 0 {
				continue
			}
			parked_now := C.vgc_atomic_load_u32(&vgc_heap.caches[ci].stopped) != 0
				&& cc.park_seq == C.vgc_atomic_load_u32(&vgc_heap.gc_stop_seq)
			if !parked_now && C.vgc_port_is_acked(cc.mach_port) == 0 {
				C.vgc_say(0x57ac, u64(u32(ci)))
			}
		}
	}
	$if vgc_keysweep ? {
		unsafe { C.memset(&vgc_ks_tab[0], 0, usize(sizeof(usize)) * usize(vgc_ks_cap)) }
		vgc_ks_count = 0
		vgc_ks_overflow = 0
	}
	for i in 0 .. vgc_heap.nspans {
		span := unsafe { vgc_heap.allspans[i] }
		if span == unsafe { nil } || !span.in_use {
			continue
		}
		vgc_sweep_span(span)
	}
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
				tc := unsafe { &vgc_heap.caches[ti] }
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
	C.vgc_atomic_store_u32(&vgc_heap.sweep_done, 1)
}

// Sweep a single span: free unmarked objects.
// Translated from Go's mspan.sweep() in mgcsweep.go.
fn vgc_sweep_span(span &VGC_Span) {
	if span.alloc_bits == unsafe { nil } || span.mark_bits == unsafe { nil } {
		return
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
		return
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
					_ = C.vgc_atomic_fetch_and_u8(&u8(voidptr(usize(span.alloc_bits) +
						usize(b))), ~garbage)
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
	mut total := u64(0)
	for i in 0 .. vgc_heap.nspans {
		span := unsafe { vgc_heap.allspans[i] }
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
	return total
}

// #58 re-mark support: count MARKED objects in the victim-class spans only
// (scan-type, elem_size 128..192 — the worker bindings keys-array class). A
// count, not bytes, so a same-roots re-mark that reaches more of them is
// directly visible.
fn vgc_count_marked_victimclass() u64 {
	mut total := u64(0)
	for i in 0 .. vgc_heap.nspans {
		span := unsafe { vgc_heap.allspans[i] }
		if span == unsafe { nil } || !span.in_use || span.mark_bits == unsafe { nil } {
			continue
		}
		if span.noscan || span.elem_size < u32(128) || span.elem_size > u32(192) {
			continue
		}
		nbytes := (span.nelems + 7) / 8
		for b in 0 .. nbytes {
			total += u64(C.vgc_popcount8(unsafe { span.mark_bits[b] }))
		}
	}
	return total
}

// Update the GC trigger point for the next cycle.
// Translated from Go's gcControllerState.endCycle() / heapGoal().
// Uses GOGC logic: trigger when heap grows to (1 + GOGC/100) * marked
fn vgc_update_trigger() {
	marked := C.vgc_atomic_load_u64(&vgc_heap.heap_marked)
	gc_percent := u64(vgc_heap.gc_percent)

	mut goal := marked + marked * gc_percent / 100
	// Avoid very small heap goals that force frequent full cycles on bursty workloads.
	if goal < vgc_base_floor {
		goal = vgc_base_floor
	}
	// Clamp to the soft heap limit: the backstop must keep firing well before the
	// physical arena ceiling regardless of how large the marked set gets (#57/#71).
	if goal > vgc_heap_soft_limit {
		goal = vgc_heap_soft_limit
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
	return in_use_bytes, free_bytes, usize(live), usize(total_alloc), usize(vgc_heap.gc_cycle)
}

fn vgc_memory_use() usize {
	mut total := usize(0)
	for i in 0 .. vgc_heap.narenas {
		total += vgc_heap.arenas[i].used
	}
	return total
}
