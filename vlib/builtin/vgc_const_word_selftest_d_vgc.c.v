module builtin

// vgc_const_word_selftest — white-box check that a V const or global of a
// pointer-free type is not a root (cx-home/cx-core-code#278, cx-examples#249).
//
// A const or `__global` whose type holds no reference (an int, a float, a bool,
// an enum, an alias of one — a duration in nanoseconds, a byte count, a clock)
// is an integer the program keeps in the data segment, and the data-segment
// root scan read every word of that segment conservatively: a value that
// falls inside the arenas' address range roots whatever is carved there. On
// macOS arm64 the arenas sit at 0x1_0000_0000-0x2_0000_0000, which is 4.3-8.6
// seconds in nanoseconds, 4-8 GB in bytes: cx-platform-store's
// `grp_shred_status_wait = 5 * time.second` (0x12a05f200) kept a dropped
// 12 MB array in cx's prof-052 row whenever the array's block was carved
// there — 91 of 96 red runs under -d vgc_rootdiag read
// `root=data sym=_const_store__grp_shred_status_wait+0 reaches=12000008 B`.
// The collector's own clocks were already excluded one by one
// (vgc_scan_data_range's own_los: vgc_gc_cpu_t0, cx-home/v#45); a program's
// consts and globals cannot be listed by hand. cgen now gives the storage of
// every such const and global a section of its own (vnoscan, see
// Gen.vgc_noscan_storage), and the data-segment scan leaves that section out
// (vgc_noscan_ranges, vgc_platform.h).
//
// The check: a 4 MB noscan block is allocated in a frame of its own, its
// address written into the probe const's storage and into the probe global
// in turn (the value saved and restored), the frame returns, a forced
// collection runs, and the live heap must have dropped the block. A control
// round with no word naming it first proves the block is otherwise
// unreachable. A last check reads the probes' addresses against the excluded
// ranges directly.
//
// Driven by bench/parallel-alloc/vgc_const_word_test.v (module main). Only
// compiled under -d vgc / -gc e (the `_d_vgc` filename suffix).
//
// Return codes: 0 = ok
//   1 = precondition: main thread not vgc-registered
//   2 = the control round kept the block (something else roots it)
//   3 = the probe const's storage naming the block kept it alive
//   4 = the probe global naming the block kept it alive
//   5 = the probe const's storage is not in an excluded range
//   6 = the probe global is not in an excluded range

const vgc_const_word_block = 4 * 1024 * 1024

// vgc_const_word_probe is an init-later const (its value is a call, so cgen
// gives it storage in the data segment, as `5 * time.second` gets).
const vgc_const_word_probe = i64(vgc_const_word_seed())

__global vgc_const_word_gprobe = i64(0)

@[noinline]
fn vgc_const_word_seed() i64 {
	return 0
}

// vgc_const_word_set writes the probe const's storage (a const is a plain
// global in C). In a frame of its own: written inline in the carve, gcc on
// Linux arm64 (-O0) left the block's address in a slot the scan counted under
// the carve's caller (root=stack frame=vgc_const_word_live fp_off=16), and the
// control round read 2 there while macOS read 0.
@[noinline]
fn vgc_const_word_set(v i64) {
	unsafe {
		mut w := &i64(voidptr(&vgc_const_word_probe))
		*w = v
	}
}

@[noinline]
fn vgc_const_word_carve(which int) {
	p := unsafe { malloc_noscan(vgc_const_word_block) }
	match which {
		1 { vgc_const_word_set(i64(p)) }
		2 { vgc_const_word_gprobe = i64(p) }
		else {}
	}
}

// vgc_const_word_live answers the live heap after one forced collection that
// follows a carve whose address only `which` names (0: nothing names it).
fn vgc_const_word_live(which int) u64 {
	vgc_force_collect()
	vgc_const_word_carve(which)
	vgc_force_collect()
	return C.vgc_atomic_load_u64(&vgc_heap.heap_live)
}

// vgc_const_word_selftest returns 0 when neither probe roots the block it
// names and both live in an excluded range, else the failed check's code
// (file header).
pub fn vgc_const_word_selftest() u32 {
	if C.vgc_get_cache_idx() < 0 {
		return 1
	}
	saved := vgc_const_word_probe
	gsaved := vgc_const_word_gprobe
	defer {
		vgc_const_word_set(saved)
		vgc_const_word_gprobe = gsaved
	}
	half := u64(vgc_const_word_block / 2)
	if vgc_const_word_live(0) >= half {
		return 2
	}
	if vgc_const_word_live(1) >= half {
		return 3
	}
	vgc_const_word_set(saved)
	if vgc_const_word_live(2) >= half {
		return 4
	}
	if !vgc_noscan_word(usize(voidptr(&vgc_const_word_probe))) {
		return 5
	}
	if !vgc_noscan_word(usize(voidptr(&vgc_const_word_gprobe))) {
		return 6
	}
	return 0
}
