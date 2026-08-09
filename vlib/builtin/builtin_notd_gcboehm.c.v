module builtin

// Just define the C functions, so that V does not error because of the missing definitions.

// Note: they will NOT be used, since calls to them are wrapped with `$if gcboehm ? { }`

fn C.GC_MALLOC(n usize) voidptr

fn C.GC_MALLOC_ATOMIC(n usize) voidptr

fn C.GC_MALLOC_UNCOLLECTABLE(n usize) voidptr

fn C.GC_REALLOC(ptr voidptr, n usize) voidptr

fn C.GC_FREE(ptr voidptr)

fn C.GC_memalign(align isize, size isize) voidptr

fn C.GC_get_heap_usage_safe(pheap_size &usize, pfree_bytes &usize, punmapped_bytes &usize, pbytes_since_gc &usize,
	ptotal_bytes &usize)

fn C.GC_get_memory_use() usize
fn C.GC_get_total_bytes() usize

fn C.GC_gcollect()

// gc_check_leaks is useful for detecting leaks, but it needs the GC to run.
// When GC is not used, it is a NOP.
pub fn gc_check_leaks() {}

// gc_is_enabled() returns true, if the GC is enabled at runtime.
// It will always return false, with `-gc none`.
// See also gc_disable() and gc_enable().
pub fn gc_is_enabled() bool {
	return false
}

// gc_enable explicitly enables the GC.
// Note, that garbage collections are done automatically, when needed in most cases,
// and also that by default the GC is on, so you do not need to enable it.
// See also gc_disable() and gc_collect().
// Note that gc_enable() is a NOP with `-gc none`.
pub fn gc_enable() {}

// gc_disable explicitly disables the GC.
// Do not forget to enable it again by calling gc_enable(), when your program is otherwise idle, and can afford it.
// See also gc_enable() and gc_collect().
// Note that gc_disable() is a NOP with `-gc none`.
pub fn gc_disable() {}

// gc_collect explicitly performs a garbage collection.
// When the GC is not on, (with `-gc none`), it is a NOP.
// Under the vgc collector (`-gc e`) it forces a full STW collection now and
// returns the collector's free-span pool to the OS, so RSS drops to the live
// set (Go's debug.FreeOSMemory analog). Automatic (pacer-triggered) cycles
// keep the pool committed for reuse and only trim it aged and budgeted.
pub fn gc_collect() {
	$if vgc ? {
		vgc_force_collect_release_os()
	}
}

// gc_pin registers `p` as a GC root until a matching gc_unpin — the V analog of Go's
// `runtime.Pinner`. Use it across an FFI boundary that parks a V/GC pointer in non-GC
// memory (e.g. a C library that holds a buffer across an async write): the PRECISE vgc
// collector cannot see such a reference through the C side and would reclaim the live
// object -> use-after-free (cx-private #63). While pinned, `p` and everything reachable
// from it survive collection. Each gc_pin MUST be balanced by exactly one gc_unpin.
// NOP under `-gc none`; under `-gc boehm` the conservative scan already covers C memory,
// so pinning is unnecessary (NOP there too — see builtin_d_gcboehm.c.v).
@[markused]
pub fn gc_pin(p voidptr) {
	$if vgc ? {
		vgc_pin(p)
	}
}

// gc_unpin removes one pin previously added by gc_pin. NOP if `p` is not pinned.
@[markused]
pub fn gc_unpin(p voidptr) {
	$if vgc ? {
		vgc_unpin(p)
	}
}

// gc_safe_region_enter marks the calling thread as parked in a GC-SAFE blocking
// region (cx #316): under the vgc collector (`-gc e`) the stop-the-world
// rendezvous then excludes it from the suspend set — no park wait, no mach
// suspend/resume, no signal-interrupted cond_wait — taking its roots from the
// entry-time stack prefix plus a callee-saved register snapshot instead. Call
// it immediately BEFORE an indefinite blocking primitive (a semaphore wait, a
// long sleep) and pair it with gc_safe_region_exit immediately AFTER the
// primitive returns. CONTRACT between the two calls (soundness — see
// vgc_safe_enter_spill in vgc_platform.h for the full statement): no GC-heap
// allocation, no stores of GC-heap pointers, and no new references to GC
// objects carried across the exit. Exit blocks while a stop-the-world is in
// progress (the world-resume handshake), so the region can never leak a
// running mutator into a live mark/sweep. NOP under boehm/none and for
// GC-unregistered threads.
@[markused]
pub fn gc_safe_region_enter() {
	$if vgc ? {
		vgc_safe_region_enter()
	}
}

// gc_safe_region_exit leaves a region opened by gc_safe_region_enter, blocking
// first if a vgc stop-the-world is currently in progress. NOP under boehm/none.
@[markused]
pub fn gc_safe_region_exit() {
	$if vgc ? {
		vgc_safe_region_exit()
	}
}

pub type FnGC_WarnCB = fn (msg &char, arg usize)

fn C.GC_get_warn_proc() FnGC_WarnCB
fn C.GC_set_warn_proc(cb FnGC_WarnCB)

// gc_get_warn_proc returns the current callback fn, that will be used for printing GC warnings.
// When the GC is not on, it is a NOP.
pub fn gc_get_warn_proc() {}

// gc_set_warn_proc sets the callback fn, that will be used for printing GC warnings.
// When the GC is not on, it is a NOP.
pub fn gc_set_warn_proc(cb FnGC_WarnCB) {}

// used by builtin_init
fn internal_gc_warn_proc_none(msg &char, arg usize) {}
