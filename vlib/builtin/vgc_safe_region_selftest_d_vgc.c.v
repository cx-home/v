// vgc_safe_region_selftest — deterministic white-box self-check for GC-safe
// blocking regions (cx #316): a thread parked inside
// gc_safe_region_enter/exit must be EXCLUDED from the cooperative STW suspend
// set (no mach suspend/resume, no park wait), its entry-time roots must
// survive collections that run while it is parked, and leaving the region
// while a stop-the-world is in progress must BLOCK until the world resumes
// (the Dekker handshake — the classic safe-region soundness crux).
//
// It lives inside module builtin so it can reach the collector internals
// (vgc_stat_mach_suspends, gc_stop_flag, vgc_force_collect); it is driven by
// bench/parallel-alloc/vgc_safe_region_test.v (a module-main test, same
// pattern as vgc_residual4_test.v). NOT @[markused]: no ordinary program
// calls it, so -skip-unused prunes it from production binaries. Only compiled
// under -d vgc / -gc e (the `_d_vgc` filename suffix).
//
// Return codes: 0 = ok
//   1 = precondition: main thread not vgc-registered
//   2 = worker never entered the safe region (spawn/register wedge)
//   3 = forced collections did not advance gc_cycle (collector wedge)
//   4 = a mach suspension happened while the ONLY other thread was parked in
//       a safe region — the suspend set is NOT the awake set (the #316 claim)
//   5 = the exit handshake did NOT block while a stop-the-world was in
//       progress — a waking thread could run through mark+sweep unscanned
//   6 = the worker's canary (reachable only from its parked frame/registers)
//       was corrupted by collections that ran while it was parked — the
//       entry-time root capture is unsound
module builtin

__global vgc_srt_stage = u32(0)
// worker: 1 = inside region, 3 = exited + verified
__global vgc_srt_release = u32(0)
// main -> worker: leave the region now
__global vgc_srt_exit_entered = u32(0)
// worker: about to call gc_safe_region_exit
__global vgc_srt_canary_ok = u32(0)
// worker: canary contents intact after the park

fn vgc_srt_worker() {
	vgc_ensure_registered()
	// Canary: a heap buffer whose ONLY reference is this frame (and possibly a
	// callee-saved register) at region entry — exactly the state the recorded
	// stack prefix + off-stack register snapshot must keep alive while the
	// collector runs full cycles around the parked thread.
	mut canary := []u64{len: 256}
	for i in 0 .. 256 {
		canary[i] = u64(i + 1) * 0x9e3779b97f4a7c15
	}
	vgc_safe_region_enter()
	C.vgc_atomic_store_u32(&vgc_srt_stage, 1)
	// "Blocked": a tight non-allocating spin — the shape that, without a safe
	// region, never reaches an alloc poll and is mach-suspended as a straggler
	// EVERY cycle. Pure atomics: the region contract (no allocation, no
	// GC-pointer stores) holds throughout.
	for C.vgc_atomic_load_u32(&vgc_srt_release) == 0 {
		C.vgc_cpu_pause()
	}
	C.vgc_atomic_store_u32(&vgc_srt_exit_entered, 1)
	vgc_safe_region_exit()
	// The world is running again; verify the canary survived the parked-time
	// collections byte-for-byte (a swept-and-recycled buffer fails this).
	mut ok := u32(1)
	for i in 0 .. 256 {
		if canary[i] != u64(i + 1) * 0x9e3779b97f4a7c15 {
			ok = 0
		}
	}
	C.vgc_atomic_store_u32(&vgc_srt_canary_ok, ok)
	C.vgc_atomic_store_u32(&vgc_srt_stage, 3)
}

// vgc_safe_region_selftest runs the three safe-region checks (rendezvous
// exclusion, exit-during-STW wedge, entry-time root soundness) against the
// live collector; returns 0 on success or the failed check's code (file header).
pub fn vgc_safe_region_selftest() u32 {
	$if vgc_legacy_stw ? {
		// The legacy mach-suspend collector deliberately IGNORES safe regions
		// (it suspends every registered thread — proven-sound behavior), so the
		// rendezvous-exclusion check would false-fail by design. Self-skip.
		return 0
	}
	if C.vgc_get_cache_idx() < 0 {
		return 1
	}
	C.vgc_start_thread(vgc_srt_worker)
	mut spins := u64(0)
	for C.vgc_atomic_load_u32(&vgc_srt_stage) < 1 {
		C.vgc_cpu_pause()
		spins++
		if spins > 10_000_000_000 {
			return 2
		}
	}
	// ── Rendezvous exclusion ── the only other thread is parked in a safe
	// region, so full collections must mach-suspend NOBODY (they must also not
	// burn the park-wait budget on it: it is excluded from `want`). The churn
	// between cycles recycles any wrongly-swept span so a canary miss cannot
	// hide behind "freed but not yet reused".
	s0 := vgc_stat_mach_suspends
	c0 := vgc_heap.gc_cycle
	for _ in 0 .. 3 {
		mut junk := []string{}
		for i in 0 .. 512 {
			junk << 'safe-region-churn-${i}-${i * 31}'
		}
		vgc_force_collect()
	}
	if vgc_heap.gc_cycle < c0 + 3 {
		return 3
	}
	if vgc_stat_mach_suspends != s0 {
		return 4
	}
	// ── Exit-during-STW wedge ── simulate an in-progress cooperative
	// stop-the-world with the REAL flag the handshake polls, release the
	// worker, and require that it does NOT get past gc_safe_region_exit until
	// the flag drops. NOTE: between the two flag stores main must not allocate
	// (an allocation would self-park in vgc_safepoint with no collector to
	// release it) — this window is pure atomics and pause loops.
	C.vgc_atomic_store_u32(&vgc_heap.gc_stop_flag, 1)
	C.vgc_atomic_store_u32(&vgc_srt_release, 1)
	for C.vgc_atomic_load_u32(&vgc_srt_exit_entered) == 0 {
		C.vgc_cpu_pause()
	}
	// Generous window (~ms) for a BROKEN handshake to run through: reaching
	// stage 3 from the exit call is nanoseconds of straight-line code.
	for _ in 0 .. 5_000_000 {
		C.vgc_cpu_pause()
	}
	blocked := C.vgc_atomic_load_u32(&vgc_srt_stage) != 3
	C.vgc_atomic_store_u32(&vgc_heap.gc_stop_flag, 0) // resume the "world"
	spins = 0
	for C.vgc_atomic_load_u32(&vgc_srt_stage) != 3 {
		C.vgc_cpu_pause()
		spins++
		if spins > 10_000_000_000 {
			return 5 // released the flag but the worker never came back
		}
	}
	if !blocked {
		return 5
	}
	if C.vgc_atomic_load_u32(&vgc_srt_canary_ok) != 1 {
		return 6
	}
	return 0
}
