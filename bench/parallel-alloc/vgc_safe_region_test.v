// CX-free deterministic regression for GC-safe blocking regions (cx #316):
// a thread parked between gc_safe_region_enter/exit is excluded from the
// cooperative STW suspend set (no mach suspend, no park wait), its entry-time
// roots survive collections that run while it is parked, and leaving the
// region while a stop-the-world is in progress blocks until the world
// resumes. This drives the white-box self-check in module builtin
// (vgc_safe_region_selftest), which exercises the real collector with a real
// second thread.
//
//   ../../v -gc e -cc cc test bench/parallel-alloc/vgc_safe_region_test.v
//
// Requires -gc e (the vgc backend); the self-check is absent under -gc boehm/none.
module main

fn test_vgc_safe_region_parked_thread_is_gc_covered_not_suspended() {
	rc := vgc_safe_region_selftest()
	// 0 = ok; 1/2/3 = setup precondition (registered main / worker entry /
	// collector cycles); 4 = parked thread was mach-suspended (rendezvous not
	// excluded); 5 = exit handshake failed to block during STW (UNSOUND);
	// 6 = entry-time roots lost while parked (UNSOUND).
	assert rc == 0
}
