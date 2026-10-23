// cx-private#2011: the passive UAF oracle must not read a foreign (libc)
// address that lies between two vgc arenas as a freed vgc buffer. On Linux
// glibc's per-thread malloc arenas land inside [vgc_arena_lo, vgc_arena_hi),
// and the concurrency-soundness gate's HTTP stressors read ~2,000 false
// "sweep-while-live" catches on picoev's C.malloc'd request buffer. The
// white-box check lives in module builtin (vgc_uaf_foreign_selftest): it
// plants the shape with no threads and keeps the true positive (a buffer
// vgc freed is still caught).
//
//   ../../v -gc e -cc cc test bench/parallel-alloc/vgc_uaf_foreign_test.v
//
// Requires -gc e (the vgc backend); the self-check is absent under -gc boehm/none.
module main

fn test_a_foreign_address_between_arenas_is_not_a_vgc_free() {
	rc := vgc_uaf_foreign_selftest()
	// 0 = ok; 1 = setup (the libc buffer is inside an arena); 2 = the foreign
	// address read as freed; 3 = a vgc-freed buffer was not caught
	assert rc == 0
}
