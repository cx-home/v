module builtin

// Stub declarations for VGC functions, so that V does not error
// because of the missing definitions in $if vgc ? { } blocks.
// Note: they will NOT be called, since calls to them are wrapped with `$if vgc ? { }`.

fn vgc_malloc(n usize) voidptr {
	return unsafe { nil }
}

fn vgc_malloc_noscan(n usize) voidptr {
	return unsafe { nil }
}

fn vgc_malloc_typed_opts(n usize, ptrmap u64, ptr_words u8, zero_fill bool) voidptr {
	return unsafe { nil }
}

fn vgc_malloc_noscan_opts(n usize, zero_fill bool) voidptr {
	return unsafe { nil }
}

fn vgc_memdup(src voidptr, n isize) voidptr {
	return unsafe { nil }
}

fn vgc_memdup_noscan(src voidptr, n isize) voidptr {
	return unsafe { nil }
}

fn vgc_realloc(old_ptr voidptr, new_size usize) voidptr {
	return unsafe { nil }
}

fn vgc_calloc(n usize) voidptr {
	return unsafe { nil }
}

fn vgc_free(ptr voidptr) {
}

fn vgc_heap_usage() (usize, usize, usize, usize, usize) {
	return 0, 0, 0, 0, 0
}

fn vgc_memory_use() usize {
	return 0
}

fn vgc_safe_region_enter() {
}

fn vgc_safe_region_exit() {
}

// The names below are read only inside `$if vgc ? {}` arms (and the cx_* / vgc_*
// diagnostic arms in map.v and string.v). A normal build drops those arms before
// checking them, but `-cross` (and `-os cross`) checks EVERY top-level branch, so
// without these declarations a cross build of any program failed in builtin with
// "unknown function: vgc_pin" / "undefined ident: vgc_heap" (cx-private#1888).
// The stubs are never reached: the C they produce sits under the vgc #if.

struct VGC_Heap {
mut:
	total_alloc u64
	gc_cycle    u64
}

struct VGC_Span {
mut:
	base      usize
	elem_size u32
}

__global vgc_heap = VGC_Heap{}
__global vgc_arena_lo = usize(0)
__global vgc_arena_hi = usize(0)
__global vgc_watch_addr = usize(0)

fn C.vgc_atomic_load_u64(ptr &u64) u64
fn C.vgc_atomic_store_u64(ptr &u64, val u64)
fn C.vgc_atomic_store_u32(ptr &u32, val u32)
fn C.vgc_atomic_cas_u32(ptr &u32, expected &u32, desired u32) bool
fn C.vgc_say(tag u64, v u64)

fn vgc_pin(p voidptr) {
}

fn vgc_unpin(p voidptr) {
}

fn vgc_force_collect_release_os() {
}

fn vgc_find_span(ptr voidptr) &VGC_Span {
	return unsafe { nil }
}

fn vgc_uaf_report(loc usize, slen int, strptr usize) {
}

fn vgc_uaf_check_buf(strptr usize, slen int) bool {
	return false
}

fn vgc_spchk_report(pkey voidptr, myframe usize) {
}
