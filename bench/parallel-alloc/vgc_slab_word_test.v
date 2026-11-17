// The collector's perm-bits slab words (vgc_perm_slab_cur, vgc_perm_slab_end)
// are integers, not roots (cx-home/cx-core-code#278): a slab's end is also the
// address of what the arena carves next to it, and the data-segment scan read
// it as a reference — cx's prof-052 kept a dropped 2.4 MB array buffer that
// way (-d vgc_rootdiag: root=data sym=vgc_perm_slab_end+0). Drives the
// white-box self-check in module builtin (vgc_slab_word_selftest).
//
//   ../../v -gc e -cc cc test bench/parallel-alloc/vgc_slab_word_test.v
//
// Requires -gc e (the vgc backend); the self-check is absent under -gc boehm/none.
module main

fn test_a_perm_slab_word_naming_a_dropped_block_does_not_keep_it() {
	rc := vgc_slab_word_selftest()
	// 0 = ok; 1 = setup precondition; 2 = the control round kept the block;
	// 3 = vgc_perm_slab_end kept it; 4 = vgc_perm_slab_cur kept it.
	assert rc == 0
}
