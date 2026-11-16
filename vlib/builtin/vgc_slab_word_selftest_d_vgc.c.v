module builtin

// vgc_slab_word_selftest — white-box check that the collector's own perm-bits
// slab words are not roots (cx-home/cx-core-code#278, cx-examples#249).
//
// vgc_perm_slab_cur and vgc_perm_slab_end are integers the collector keeps in
// the data segment: the bump cursor and the end of the 64 KB chunk it carves
// perm_bits + young_bits rows from (vgc_perm_bits_alloc). The data-segment
// root scan reads every word conservatively except the collector's own
// region-address words (vgc_scan_data_range, cx-private#1783 / cx-home/v#15),
// and these two were not among them: a slab's end is also the address of
// whatever the arena carves next to it, so the word rooted that object for as
// long as the slab stayed current. cx's prof-052 (a 100,000-item array built
// and dropped between two forced collections) read 2,413,096 bytes too many
// in heap-bytes whenever the array's 2.4 MB item buffer was carved at that
// address — under VGC_CM=1, or on a loaded box where the collector picks the
// concurrent cycle, which allocates the slab; -d vgc_rootdiag named the word
// (root=data sym=vgc_perm_slab_end+0 reaches=2400008 B objs=1).
//
// The check: a 4 MB noscan block is allocated in a frame of its own, its
// address written to each slab word in turn (the value saved and restored), the
// frame returns, a forced collection runs, and the live heap must have dropped
// the block. A control round with no word naming it first proves the block is
// otherwise unreachable.
//
// Driven by bench/parallel-alloc/vgc_slab_word_test.v (module main). Only
// compiled under -d vgc / -gc e (the `_d_vgc` filename suffix).
//
// Return codes: 0 = ok
//   1 = precondition: main thread not vgc-registered
//   2 = the control round kept the block (something else roots it)
//   3 = vgc_perm_slab_end naming the block kept it alive
//   4 = vgc_perm_slab_cur naming the block kept it alive

const vgc_slab_word_block = 4 * 1024 * 1024

@[noinline]
fn vgc_slab_word_carve(which int) {
	p := unsafe { malloc_noscan(vgc_slab_word_block) }
	match which {
		1 { vgc_perm_slab_end = usize(p) }
		2 { vgc_perm_slab_cur = usize(p) }
		else {}
	}
}

// vgc_slab_word_live answers the live heap after one forced collection that
// follows a carve whose address only `which` names (0: nothing names it).
fn vgc_slab_word_live(which int) u64 {
	vgc_force_collect()
	vgc_slab_word_carve(which)
	vgc_force_collect()
	return C.vgc_atomic_load_u64(&vgc_heap.heap_live)
}

// vgc_slab_word_selftest returns 0 when neither slab word roots the block it
// names, else the failed check's code (file header).
pub fn vgc_slab_word_selftest() u32 {
	if C.vgc_get_cache_idx() < 0 {
		return 1
	}
	cur := vgc_perm_slab_cur
	end := vgc_perm_slab_end
	defer {
		vgc_perm_slab_cur = cur
		vgc_perm_slab_end = end
	}
	half := u64(vgc_slab_word_block / 2)
	if vgc_slab_word_live(0) >= half {
		return 2
	}
	if vgc_slab_word_live(1) >= half {
		return 3
	}
	vgc_perm_slab_end = end
	if vgc_slab_word_live(2) >= half {
		return 4
	}
	return 0
}
