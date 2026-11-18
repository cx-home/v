// A V const or global of a pointer-free type (an int, a float, a bool, an
// enum, an alias of one) is an integer, not a root (cx-home/cx-core-code#278):
// its storage in the data segment was scanned conservatively, and a value in
// the arenas' address range rooted whatever was carved there — cx's prof-052
// kept a dropped 12 MB array through cx-platform-store's
// `grp_shred_status_wait = 5 * time.second` (0x12a05f200;
// -d vgc_rootdiag: root=data sym=_const_store__grp_shred_status_wait+0).
// Drives the white-box self-check in module builtin (vgc_const_word_selftest).
//
//   ../../v -gc e -cc cc test bench/parallel-alloc/vgc_const_word_test.v
//
// Requires -gc e (the vgc backend); the self-check is absent under -gc boehm/none.
module main

fn test_a_pointer_free_const_or_global_naming_a_dropped_block_does_not_keep_it() {
	rc := vgc_const_word_selftest()
	// 0 = ok; 1 = setup precondition; 2 = the control round kept the block;
	// 3 = the probe const kept it; 4 = the probe global kept it;
	// 5 / 6 = the probe const / global is not in an excluded range.
	assert rc == 0
}
