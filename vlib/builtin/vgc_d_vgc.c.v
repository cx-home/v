// vgc_d_vgc.c.v - V Garbage Collector: Core types, heap, and allocation
// Translated from Go's runtime GC (golang/go src/runtime/malloc.go, mheap.go, mspan.go, mcache.go, mcentral.go)
// Concurrent tri-color mark-and-sweep garbage collector with size-class allocation.

@[has_globals]
module builtin

#flag -I @VEXEROOT/thirdparty/vgc
#include "vgc_platform.h"

// C interop declarations for platform header
fn C.vgc_get_cache_idx() int
fn C.vgc_set_cache_idx(idx int)
fn C.vgc_atomic_load_u32(ptr &u32) u32
fn C.vgc_atomic_store_u32(ptr &u32, val u32)
fn C.vgc_alloc_try_enter() int // coarse-alloc re-entrancy guard (-d vgc_coarse_alloc)
fn C.vgc_alloc_exit()
fn C.vgc_atomic_load_u64(ptr &u64) u64
fn C.vgc_atomic_store_u64(ptr &u64, val u64)
fn C.vgc_atomic_add_u64(ptr &u64, val u64) u64
fn C.vgc_atomic_sub_u64(ptr &u64, val u64) u64
fn C.vgc_atomic_sub_u32(ptr &u32, val u32) u32
fn C.vgc_atomic_fetch_or_u8(ptr &u8, val u8) u8
fn C.vgc_atomic_fetch_and_u8(ptr &u8, val u8) u8
fn C.vgc_atomic_add_u32(ptr &u32, val u32) u32
fn C.vgc_atomic_cas_u32(ptr &u32, expected &u32, desired u32) bool
fn C.vgc_atomic_exchange_u32(ptr &u32, val u32) u32
fn C.vgc_atomic_fence()
fn C.vgc_os_alloc(size usize) voidptr
fn C.vgc_os_free(ptr voidptr, size usize)
fn C.vgc_os_decommit(ptr voidptr, size usize)
fn C.vgc_get_sp() voidptr
fn C.vgc_get_stack_bounds(lo &usize, hi &usize) int
fn C.vgc_bitmap_get(bits &u8, idx u32) int
fn C.vgc_bitmap_set(bits &u8, idx u32)
fn C.vgc_bitmap_clear(bits &u8, idx u32)
fn C.vgc_bitmap_test_and_set(bits &u8, idx u32) int
fn C.vgc_popcount8(x u8) int
fn C.vgc_size_class(size u32) u8
fn C.vgc_get_class_size(cls int) u32
fn C.vgc_get_class_npages(cls int) u32
fn C.vgc_get_class_nobjs(cls int) u32
fn C.vgc_init_size_tables()
fn C.vgc_mutex_lock(lk &u32)
fn C.vgc_mutex_unlock(lk &u32)
fn C.vgc_start_thread(f voidptr)
fn C.vgc_install_thread_exit(idx int)
fn C.vgc_park_spill(stop_flag &u32, stopped_count &u32, my_stopped &u32, range_lo &usize, range_hi &usize, stack_base usize)
fn C.vgc_thread_self_port() u32
fn C.vgc_suspend_thread(t u32) int // 1 = target acked/parked; 0 = target gone (skip safely)
fn C.vgc_resume_thread(t u32)
fn C.vgc_thread_regs(t u32, sp_out &usize, regs &usize, max int) int
fn C.vgc_run_gc_spilled(range_lo &usize, range_hi &usize, stack_base usize)
fn C.vgc_num_cpus() int

// Optional diagnostic trace ring — no-ops unless built with `-cflags -DVGC_DIAG`.
fn C.vgc_trace(ev int, slot int, a u64, b u64)
fn C.vgc_trace_init()
fn C.vgc_say(tag u64, v u64) // loud one-line stderr note (used by the span-registry abort)
fn C.vgc_ra0() voidptr // #58 freering: __builtin_return_address(0) of the calling V fn
fn C.vgc_ra1() voidptr // #58 freering: one frame up (the codegen free/drop site)
fn C.vgc_ra2() voidptr // #58 freering: two frames up
fn C.vgc_ra_anchor() voidptr // #58 freering: text-segment anchor for ASLR slide
fn C.vgc_real_sp() usize // actual SP register (see vgc_platform.h)
fn C.vgc_gctrace_line(cycle u64, marked u64, goal u64, narenas u64, nspans u64, lthreads u64) // VGC_GCTRACE=1 per-cycle line
fn C.vgc_verify_report(kind u64, referrer_addr u64, referrer_size u64, off u64, referent_addr u64, referent_size u64) // mark-closure verifier (-d vgc_verify)
fn C.vgc_rootfind_enumerate(arena_lo u64, arena_hi u64) // /proc/self/maps root-finder (-d vgc_verify)
fn C.vgc_rootfind_report(referrer u64, in_stack int, target u64, tsz u64, kind u64) // root-finder hit reporter
fn C.abort()

fn C.vgc_addr_map_register(base usize, size usize, arena_idx int)
fn C.vgc_addr_to_arena(addr usize) int

// ============================================================
// Constants (translated from Go's runtime constants)
// ============================================================

const vgc_page_shift = 13
const vgc_page_size = 8192
const vgc_max_small_size = u32(32768) // objects > this are "large"
const vgc_num_classes = 68
const vgc_num_span_classes = 136 // 68 * 2 (scan + noscan variants)
const vgc_arena_size = usize(64) * 1024 * 1024 // 64MB per arena
const vgc_pages_per_arena = vgc_arena_size / vgc_page_size
// free_spans pool bound: spans of 1..vgc_max_pooled_pages-1 pages are recyclable.
// A literal (not the computed vgc_pages_per_arena) because V needs a constant-literal
// for the fixed-array size below. 8192 pages * 8 KB = 64 MB = one full arena, so every
// span that can fit in an arena is poolable (#52/#57: the old 32-page/256 KB bound
// silently leaked larger transients).
const vgc_max_pooled_pages = 8192
const vgc_max_arenas = 64
const vgc_max_threads = 64
const vgc_tiny_size = 16 // tiny allocator threshold (no-pointer objects < 16 bytes)

// GC phases (translated from Go's _GCoff, _GCmark, _GCmarktermination)
const vgc_phase_off = u32(0)
const vgc_phase_mark = u32(1)
const vgc_phase_mark_term = u32(2)
const vgc_phase_sweep = u32(3)

// ============================================================
// Core types (translated from Go's mspan, mheap, mcache, mcentral)
// ============================================================

// VGC_Span represents a run of contiguous pages containing objects of one size class.
// Translated from Go's runtime.mspan.
struct VGC_Span {
mut:
	base       usize // start address of the span
	npages     u32   // number of pages in this span
	elem_size  u32   // size of each object in bytes
	nelems     u32   // number of elements (objects) in the span
	class_idx  u8    // size class index (0 for large objects)
	noscan     bool  // true if objects contain no pointers (noscan variant)
	in_use     bool  // true if span is allocated to a size class
	has_ptrmap bool  // true if ptrmap is valid (precise scanning available)
	is_tiny    bool  // true if the tiny allocator carved a packed block from this span
	// (multiple independently-allocated sub-objects share one slot; an individual
	// free must NOT reclaim such a slot — see vgc_free / the tiny allocator).
	// Pointer bitmap: bit N = word offset N contains a pointer.
	// Covers objects up to 512 bytes (64 words on 64-bit).
	// For larger objects, falls back to conservative scanning.
	ptrmap u64
	// Number of pointer words in the object (for precise scanning)
	ptr_words u8
	// Allocation bitmaps (translated from Go's allocBits/gcmarkBits)
	alloc_bits  &u8 = unsafe { nil } // 1 = allocated
	mark_bits   &u8 = unsafe { nil } // 1 = marked (used during GC)
	alloc_count u32 // number of currently allocated objects
	free_index  u32 // hint: scan from here for free slot
	// Sweep generation (translated from Go's sweepgen)
	sweep_gen u32
	// Concurrent mark (vgc_concurrent): set to 1 by the write barrier
	// (vgc_wb_store) when any object in this span is mutated during the
	// concurrent mark; the collector conservatively re-scans every dirty span at
	// mark-termination (vgc_rescan_dirty_spans), then clears it. Unused (always 0)
	// under the default STW build.
	dirty u32
	// Linked list pointers — SHARED between the central partial/full lists and the
	// free_spans recycle list (a span is on at most one at a time).
	next &VGC_Span = unsafe { nil }
	prev &VGC_Span = unsafe { nil }
	// Which central list this span is currently linked on: 0=none, 1=partial, 2=full.
	// The sweep MUST unlink a span from its central list before recycling it via
	// vgc_put_free_span (which reuses `next`); otherwise the central list's `next`
	// chain is hijacked into free_spans -> a later vgc_central_get_span traverses a
	// garbage node -> returns a wild span -> SIGSEGV in the allocation memset.
	on_central u8
	// INLINE allocation / mark bitmaps. The max objects per span across all size
	// classes is 1024 (vgc_class_nobjs[1]) -> 128 bytes; large spans use 1 byte.
	// Inlining (vs a per-bitmap mmap) avoids rounding each ~128-byte bitmap up to a
	// full page — that wasted gigabytes of RSS and forced a per-span mmap+munmap
	// every pool/reuse (munmap's cross-core TLB shootdowns dominated GC wall-clock).
	// alloc_bits / mark_bits point into these buffers; the span struct never moves.
	alloc_buf [136]u8
	mark_buf  [136]u8
}

// VGC_Cache is a per-thread allocation cache.
// Translated from Go's runtime.mcache - eliminates lock contention on hot path.
struct VGC_Cache {
mut:
	alloc [136]&VGC_Span // one span per span class (68 scan + 68 noscan)
	// Tiny allocator for objects < 16 bytes without pointers
	// Translated from Go's mcache.tiny
	tiny        usize
	tiny_offset usize
	tiny_allocs usize
	// Thread info
	registered bool
	stack_base usize // fixed stack boundary for this thread
	stack_lo   usize // lowest stack address (for root scanning)
	stack_hi   usize // highest stack address
	thread_id  u64
	stopped    u32 // 1 if stopped for GC
	mach_port  u32 // OS thread handle for OS-level suspend-the-world (darwin)
	// Per-thread heap accounting (Go per-P style). The alloc/free fast path bumps
	// these THREAD-PRIVATE counters (no shared atomic), flushing into the global
	// heap_live/total_alloc only every ~vgc_acct_flush bytes. This removes the
	// global-atomic cacheline contention that made alloc-heavy MP anti-scale
	// (R2-E-FINDINGS.md): balanced alloc/free keeps live_delta near zero, so the
	// hot path never touches a shared line. Only this thread writes its own slot;
	// the collector reads/resets all slots under STW.
	live_delta  i64 // un-flushed (allocated - freed) bytes by this thread
	alloc_delta u64 // un-flushed total-allocated bytes by this thread
}

// VGC_Central is a central free list for one span class.
// Translated from Go's runtime.mcentral.
struct VGC_Central {
mut:
	lock    u32 // spinlock
	partial &VGC_Span = unsafe { nil } // spans with free objects (swept)
	full    &VGC_Span = unsafe { nil } // spans with no free objects
}

// VGC_Arena tracks a chunk of memory obtained from the OS.
// Translated from Go's heapArena concept.
struct VGC_Arena {
mut:
	base usize
	size usize
	used usize
	// Map from page index to span (for finding which span owns an address)
	page_span [8192]&VGC_Span // vgc_pages_per_arena entries
}

// VGC_WorkBuf is a work buffer for the mark phase.
// Translated from Go's runtime.workbuf.
struct VGC_WorkBuf {
mut:
	nobj int
	obj  [256]usize // pointers to mark
	next &VGC_WorkBuf = unsafe { nil }
}

// VGC_Heap is the global heap.
// Translated from Go's runtime.mheap.
struct VGC_Heap {
mut:
	lock u32 // spinlock
	// Arenas (memory from OS)
	arenas  [64]VGC_Arena
	narenas int
	// Central free lists (one per span class)
	central [136]VGC_Central
	// Large object spans
	large_alloc &VGC_Span = unsafe { nil }
	// All spans, for iteration during GC. mmap-backed (lazily on first span_alloc),
	// lazily committed by the OS so the reservation costs ~nothing until filled. The
	// pointer is allocated ONCE and never moves, so the collector's lock-free allspans
	// walks (incl. lazy sweep outside STW) never observe a relocated/freed buffer —
	// sidestepping the realloc race that runtime doubling would introduce. Capacity is
	// load-bearing: span reuse + the sweep_gen one-cycle grace make the live span
	// count ~2x the heap-goal working set, and per-thread GC pacing
	// (vgc_pace_by_threads) raises the heap goal ~N x for N mutators, so an alloc-heavy
	// [par] workload needs far more than the old fixed 262144. vgc_span_alloc fails
	// loudly (never silently) past cap.
	allspans     &&VGC_Span = unsafe { nil }
	allspans_cap int
	nspans       int
	// Free spans (completely empty, reusable by page count)
	free_spans_lock u32
	// free spans indexed by npages (1..vgc_pages_per_arena-1, 0=unused). Sized to a
	// full arena so EVERY span that fits in one arena is recyclable. The old [32]
	// bound (256 KB) silently leaked larger transients (e.g. a ~1 MB zstd dst buffer
	// in a streaming-write hot loop): swept empty, but vgc_put_free_span/_get_free_span
	// refused npages>=32, so the span was never pooled and the arena bump pointer
	// (never rewound) kept advancing → unbounded RSS. cx-private #52/#57.
	free_spans      [vgc_max_pooled_pages]&VGC_Span
	// Per-thread caches
	caches       [64]VGC_Cache
	ncaches      int // high-water mark of slots ever used
	live_threads u32 // atomic-ish (guarded by cache_lock): currently-registered mutators
	free_slots   [64]int // reclaimed cache indices, reused before growing ncaches
	nfree_slots  int
	cache_lock   u32
	// GC state
	gc_phase   u32 // atomic: current GC phase
	gc_enabled u32 // atomic: 1 = GC enabled
	sweep_gen  u32 // current sweep generation
	wb_enabled u32 // atomic: write barrier enabled
	// GC metrics (translated from Go's gcController)
	heap_live   u64 // atomic: bytes of live heap objects (actual object bytes)
	heap_marked u64 // bytes marked in last cycle
	next_gc     u64 // trigger next GC at this heap size
	total_alloc u64 // atomic: total bytes allocated
	gc_cycle    u64 // number of completed GC cycles
	// GC work queues
	work_full  &VGC_WorkBuf = unsafe { nil }
	work_empty &VGC_WorkBuf = unsafe { nil }
	work_lock  u32
	// GC worker coordination
	gc_workers_done  u32 // atomic
	gc_nworkers      int
	gc_stop_flag     u32 // atomic: tells threads to stop for GC
	gc_stopped_count u32 // atomic: threads stopped
	gc_target_stops  u32 // number of threads to stop
	// Sweep state
	sweep_idx  int
	sweep_done u32 // atomic
	// Default GC trigger: collect when heap doubles (GOGC=100 equivalent)
	gc_percent int // like Go's GOGC, default 100
	// Span-descriptor slab (bump allocator for VGC_Span metadata). Span descriptors are
	// never individually freed (vgc_put_free_span pools them for reuse forever), so a
	// bump slab is sound and removes a per-carve mmap() syscall from the vgc_heap.lock
	// hold — that syscall lengthened the lock hold and drove the new-span-carve
	// contention that makes alloc-heavy [par] anti-scale (B18). Bumped under vgc_heap.lock.
	span_meta_cur usize
	span_meta_end usize
}

// Global heap instance. NOTE: V emits a zero-initializing assignment for this
// global inside `_vinit()` regardless of the source initializer, so vgc_init()
// MUST run AFTER _vinit() (cmain.v) or its gc_enabled/next_gc setup is wiped.
__global vgc_heap = VGC_Heap{}
// Coarse allocator lock (-d vgc_coarse_alloc only): serializes all mutator
// malloc/free/realloc to confirm/baseline the residual allocator data race.
__global vgc_alloc_lock = u32(0)
// Fast bounds check for pointer validation
__global vgc_arena_lo = usize(0)
__global vgc_arena_hi = usize(0)

// Spawn-argument roots. `spawn f(...)` heap-allocates a thread-argument struct
// (builtin___v_malloc), fills it, and hands it to pthread_create. Between create
// and the child reading it, that struct is reachable from NO scanned root: the
// spawning thread has dropped its local, and the child is not yet vgc-registered
// (it registers lazily on its first allocation, which happens INSIDE the spawned
// fn, after the wrapper has already dereferenced the arg). A collection in that
// window would sweep the live arg struct -> the wrapper reads freed/reused memory.
// (This is the real "bug B" thread-churn defect — not allocator slot-reuse.)
// The spawning thread registers the arg here before pthread_create; the wrapper
// releases it after the call. While registered, the collector shades it (and,
// being a scan object, its referents) every STW cycle.
const vgc_max_spawn_roots = 1024
__global vgc_spawn_roots = [1024]voidptr{}
__global vgc_nspawn_roots = int(0)
__global vgc_spawn_root_lock = u32(0)

// ============================================================
// Pinner — cgo-safe explicit roots (the Go `runtime.Pinner` analog)
// ============================================================
// A live GC object reachable ONLY from non-GC memory (a libc-malloc'd / anon C
// structure the FFI boundary holds across a call — e.g. the picoev transport
// holding a per-request buffer across an async write) is INVISIBLE to vgc's precise
// root scan (globals + stacks + heap), so the collector reclaims it -> use-after-free
// (cx-private #63, the multi-reactor HTTP residual). Go's GC has the same blind spot
// and forbids it by rule ("C code must not keep a Go pointer after the call returns")
// while offering runtime.Pinner for the legitimate case. This is that primitive:
// vgc_pin(p) adds p to a set the collector SHADES as a root every cycle (so p and
// everything transitively reachable from it survive); vgc_unpin(p) drops one pin.
// The FFI shim pins for exactly the window C holds the pointer. Cheap (a set scan per
// GC), unlike conservatively scanning all of C memory (~44x HTTP slowdown, rejected).
//
// Pins are NOT deduplicated: each vgc_pin adds a slot and each vgc_unpin removes one,
// so N pins of the same object need N unpins (de-facto refcount — safe when distinct
// owners pin a shared object). Concurrency: pin/unpin take vgc_pin_lock
// (mutator-vs-mutator). The collector reads the slots LOCK-FREE under STW (frozen
// mutators): each slot is one aligned usize (no torn read), and unpin's swap-remove
// writes the moved value to its new slot BEFORE shrinking the count, so a frozen
// mid-unpin leaves every still-pinned address present in >=1 slot (at worst shaded
// twice for one cycle — harmless). Same discipline as vgc_spawn_roots.
const vgc_pin_cap = 65536 // max concurrent pins; the array (512 KB) is scanned each GC
__global vgc_pins = [vgc_pin_cap]voidptr{}
__global vgc_npins = int(0)
__global vgc_pin_lock = u32(0)

// vgc_pin registers p as a root until a matching vgc_unpin. Idempotent on nil.
@[markused]
fn vgc_pin(p voidptr) {
	if p == unsafe { nil } {
		return
	}
	C.vgc_mutex_lock(&vgc_pin_lock)
	if vgc_npins < vgc_pin_cap {
		unsafe {
			vgc_pins[vgc_npins] = p
		}
		// Publish the slot BEFORE bumping the count: the collector reads [0,npins)
		// lock-free under STW and must never observe an uncounted/half-written slot.
		C.vgc_atomic_fence()
		vgc_npins++
	} else {
		// Full ⇒ a pin/unpin leak (cap is far above any real in-flight set). Loud,
		// never silent: an unpinned live root would reintroduce the #63 UAF.
		C.vgc_say(0x9171, u64(usize(p))) // PINNER FULL
	}
	C.vgc_mutex_unlock(&vgc_pin_lock)
}

// vgc_unpin removes ONE pin of p (the most recently added matching slot). No-op if
// p was never pinned / already fully unpinned.
@[markused]
fn vgc_unpin(p voidptr) {
	if p == unsafe { nil } {
		return
	}
	C.vgc_mutex_lock(&vgc_pin_lock)
	mut k := vgc_npins - 1
	for k >= 0 {
		if unsafe { vgc_pins[k] } == p {
			last := vgc_npins - 1
			// Move the last slot into k BEFORE shrinking npins, so the lock-free
			// collector read never loses a still-pinned address mid-unpin.
			unsafe {
				vgc_pins[k] = vgc_pins[last]
			}
			C.vgc_atomic_fence()
			vgc_npins = last
			C.vgc_mutex_unlock(&vgc_pin_lock)
			return
		}
		k--
	}
	C.vgc_mutex_unlock(&vgc_pin_lock)
}

// ============================================================
// Initialization
// ============================================================

// Per-thread GC pacing + trigger-floor knobs. VGC_NEXT_GC_MB raises the GC trigger
// floor (MB). Per-thread pacing scales the live trigger by the live mutator count so N
// concurrent allocators don't trip the shared trigger N x more often per unit of
// per-thread progress — recovering parallel alloc-heavy scaling under the full-STW
// backstop. It is ON BY DEFAULT (B18): it is adaptive (no effect when live_threads<=1,
// so single-threaded / small programs keep the historic 256 MB trigger and RSS), and
// with the B18 allocator fixes (descriptor slab + drop-return) it gives ~2.9x [par]
// scaling at bounded RSS (~2.3 GB on the #14 workload). Set VGC_PACE=0 to disable it
// (escape hatch); any other VGC_PACE value forces it on.
__global vgc_base_floor = u64(256 * 1024 * 1024)
__global vgc_pace_by_threads = true
// VGC_GCTRACE=1 enables the per-cycle pacing trace (vgc_gctrace_line): cycle,
// marked, goal, arenas, spans, live threads. Permanent observability (GODEBUG=
// gctrace analog) — costs one integer test per cycle when off.
__global vgc_gctrace = u32(0)
// Per-extra-mutator pacing headroom (bytes; VGC_PACE_MB overrides). Replaces the
// former MULTIPLICATIVE per-thread goal scaling (`goal *= live_threads`), which
// was unsound as policy: on a many-threaded server it scaled the WHOLE live-set
// goal by N (e.g. marked 558 MB x2 x9 threads = a 10 GB trigger, beyond the 4 GB
// arena capacity), so the pacer never fired again and the heap rode arena
// exhaustion until an allocation burst failed => the #57 field OOM
// (`V panic: memory allocation failure` at RSS ~4.6 GB). Only the per-thread
// allocation SLACK should scale with thread count, and additively.
__global vgc_thread_headroom = u64(128 * 1024 * 1024)
// Soft heap limit (bytes; VGC_MEMLIMIT_MB overrides): the pacer goal is clamped
// here so collection always engages well before the physical arena ceiling
// (vgc_max_arenas * vgc_arena_size = 4 GB). Default = half the arena capacity.
// Go's GOMEMLIMIT analog for the backstop collector.
__global vgc_heap_soft_limit = u64(2) * 1024 * 1024 * 1024

// ── #58 SCANNED-WINDOW SHADOW (-d vgc_spcheck) ──────────────────────────────
// Per-thread snapshot of the [stack_lo, stack_hi] range the collector actually
// scanned at the most recent GC, plus whether the thread was a cooperative
// parker (stopped==1) or a signal-suspended straggler. On a bf1 UAF catch the
// reading mutator compares the SOURCE map struct's address and its current
// frame depth against its own last-scanned window — a holder frame below the
// scanned lo is the root-miss, localized. Written only under STW; read only on
// the rare catch path — cannot mask.
__global vgc_spchk_lo = [64]usize{}
__global vgc_spchk_hi = [64]usize{}
__global vgc_spchk_cyc = [64]u64{}
__global vgc_spchk_parked = [64]u64{}

// vgc_map_backing_status: #58 cx_envcheck probe support. Reports whether a live
// map's key/value backing arrays are still ALLOCATED in the vgc heap. An
// interpreter-held env whose bindings map has a freed (alloc-bit-clear) backing
// array is the sweep-while-live UAF caught at its source. Packed result:
// byte0 = keys status (bit0 alloc, bit1 span in_use, 0xff = not a heap ptr),
// byte1 = values status, bytes2-5 = map len (u32).
@[markused]
pub fn vgc_map_backing_status(mp voidptr) u64 {
	mut ks := u64(0xff)
	mut vs := u64(0xff)
	mut mlen := u64(0)
	unsafe {
		m := &map(mp)
		mlen = u64(u32(m.len))
		if usize(voidptr(m.key_values.keys)) >= vgc_arena_lo
			&& usize(voidptr(m.key_values.keys)) < vgc_arena_hi {
			ks = vgc_is_allocated(voidptr(m.key_values.keys)) & 3
		}
		if usize(voidptr(m.key_values.values)) >= vgc_arena_lo
			&& usize(voidptr(m.key_values.values)) < vgc_arena_hi {
			vs = vgc_is_allocated(voidptr(m.key_values.values)) & 3
		}
	}
	return ks | (vs << 8) | (mlen << 16)
}

// vgc_spchk_self: #58 cx_envcheck support — this thread's scanned-window shadow
// from the most recent GC: (cache_idx, lo, hi, cycles_since, parked). Valid only
// when the collector snapshots the shadow (-d vgc_spcheck builds); otherwise
// returns zeros. Lets an eval-side probe test whether an address it holds live
// was inside the window the collector actually scanned.
@[markused]
pub fn vgc_spchk_self() (int, usize, usize, u64, u64) {
	cidx := C.vgc_get_cache_idx()
	if cidx < 0 || cidx >= 64 {
		return -1, usize(0), usize(0), u64(0), u64(0)
	}
	return cidx, vgc_spchk_lo[cidx], vgc_spchk_hi[cidx], u64(vgc_heap.gc_cycle) - vgc_spchk_cyc[cidx], vgc_spchk_parked[cidx]
}

// vgc_addr_status: #58 cx_envcheck support — packed vgc view of an arbitrary
// address: 0xff = not in the arena; else bit0 = alloc-bit set, bit1 = span
// in_use (vgc_is_allocated low bits).
@[markused]
pub fn vgc_addr_status(p voidptr) u64 {
	if usize(p) < vgc_arena_lo || usize(p) >= vgc_arena_hi {
		return 0xff
	}
	return vgc_is_allocated(p) & 3
}

// vgc_explicit_free_ra: #58 cx_envcheck support — was `p` (an object base)
// explicitly freed recently? Scans the -d vgc_freering ring newest→oldest and
// returns the freeing call's ra1 (the codegen free site) or 0 if not found
// (=> the alloc-bit clear came from the GC sweep). Zero unless the build also
// carries -d vgc_freering.
@[markused]
pub fn vgc_explicit_free_ra(p voidptr) u64 {
	$if vgc_freering ? {
		total := C.vgc_atomic_load_u32(&vgc_freering_idx)
		mut n := u32(vgc_freering_size)
		if total < n {
			n = total
		}
		for k in 0 .. int(n) {
			i := int((total - 1 - u32(k)) & u32(vgc_freering_size - 1))
			rp := vgc_freering_ptrs[i]
			if rp != 0 && usize(p) >= rp && usize(p) - rp < 64 {
				return u64(vgc_freering_ra1s[i])
			}
		}
	}
	return 0
}

// vgc_map_keys_ptr: #58 cx_envcheck support — the raw keys backing pointer of a
// map, for ring lookups / correlation from outside builtin.
@[markused]
pub fn vgc_map_keys_ptr(mp voidptr) voidptr {
	unsafe {
		m := &map(mp)
		return voidptr(m.key_values.keys)
	}
}

// vgc_current_sp: #58 cx_envcheck support — the caller's REAL stack pointer via
// the C-level vgc_real_sp(). (A V-level `&local` probe gets heap-boxed by escape
// analysis the moment its address is taken, yielding an arena address — which
// silently invalidated an earlier above/below-frame discriminator.)
@[markused]
pub fn vgc_current_sp() usize {
	return usize(C.vgc_real_sp())
}

__global vgc_envchk_last = usize(0)

// vgc_envcheck_dedupe: true iff `p` differs from the previously reported env
// (racy across threads by design — a diagnostic dedupe, not a correctness gate).
@[markused]
pub fn vgc_envcheck_dedupe(p usize) bool {
	if p == vgc_envchk_last {
		return false
	}
	vgc_envchk_last = p
	return true
}

// ── #58 BIRTH REGISTRY (-d vgc_birthcheck) ──────────────────────────────────
// Direct-mapped: ptr -> gc_cycle at allocation, for victim-class objects.
// Collisions overwrite (younger birth wins — fine: we only ask about recent
// allocations). Lookup miss => born before the table wrapped (old object).
__global vgc_birth_ptr = [262144]usize{}
__global vgc_birth_cyc = [262144]u64{}

@[inline]
fn vgc_birth_record(addr usize) {
	i := int((u64(addr) * u64(0x9E3779B97F4A7C15)) >> 46)
	vgc_birth_ptr[i] = addr
	vgc_birth_cyc[i] = u64(vgc_heap.gc_cycle)
}

// vgc_birth_delta: cycles between `p`'s recorded birth and now; -1 = unknown.
@[markused]
pub fn vgc_birth_delta(p voidptr) i64 {
	i := int((u64(usize(p)) * u64(0x9E3779B97F4A7C15)) >> 46)
	if vgc_birth_ptr[i] != usize(p) {
		return -1
	}
	return i64(u64(vgc_heap.gc_cycle) - vgc_birth_cyc[i])
}

__global vgc_envchk_tick = u64(0)

// vgc_envcheck_sample: cheap 1-in-256 sampler for probes on ultra-hot paths
// (eval_node runs millions/s; the full map-status check there made rounds ~20x
// slower). A dead env evaluates thousands of nodes, so sampling costs no
// detection coverage — only a bounded first-report latency. Racy on purpose.
@[markused]
pub fn vgc_envcheck_sample() bool {
	vgc_envchk_tick++
	return (vgc_envchk_tick & 0xff) == 0
}

// ── #58 SWEEP-TIME ROOT FORENSIC (-d vgc_keysweep) ──────────────────────────
// vgc_sweep_span records every scan-class, keys-array-sized object it frees;
// vgc_do_sweep then (still under STW) rescans every registered thread window
// for words pointing into those objects. See vgc_do_sweep for the verdict tags.
const vgc_ks_cap = 262144 // 2^18 direct-mapped slots (~2 MB BSS; ~120k candidates/GC observed)

__global vgc_ks_tab = [262144]usize{} // freed-object BASE address (0 = empty slot)
__global vgc_ks_count = u32(0)
__global vgc_ks_overflow = u32(0)

// The earlier sorted-buffer design could not keep up: the [?let] clone churn
// frees ~100k keys-array-class objects PER CYCLE, overflowing any bounded
// append buffer (silently voiding the negative verdict) and the per-cycle sort
// made rounds minutes long. Direct-mapped open-addressing hash instead: O(1)
// insert per freed object, O(1) probe per stack word, no sort. EXACT base-
// pointer matching only — the holder word of interest (a map struct's
// key_values.keys field) IS a base pointer; interior cursors are out of scope.
@[inline]
fn vgc_ks_hash(a usize) int {
	return int((u64(a) * u64(0x9E3779B97F4A7C15)) >> 46)
}

@[inline]
fn vgc_ks_insert(base usize) {
	h := vgc_ks_hash(base)
	for probe in 0 .. 8 {
		i := (h + probe) & (vgc_ks_cap - 1)
		if vgc_ks_tab[i] == 0 {
			vgc_ks_tab[i] = base
			vgc_ks_count++
			return
		}
	}
	vgc_ks_overflow++
}

@[inline]
fn vgc_ks_lookup(val usize) bool {
	h := vgc_ks_hash(val)
	for probe in 0 .. 8 {
		i := (h + probe) & (vgc_ks_cap - 1)
		t := vgc_ks_tab[i]
		if t == 0 {
			return false
		}
		if t == val {
			return true
		}
	}
	return false
}

// vgc_spchk_report: catch-side emitter (called from map_clone_string on a bf1
// catch under -d vgc_spcheck). 0x51ee/ef = this thread's last-scanned [lo,hi];
// 0x51f0 = the catching frame; 0x51f1 = GC cycles since that scan; 0x51f2 =
// parked(1)/straggler(0) at that scan; 0x51fa = alloc status of the keys-array
// slot (bit0 alloc, bit1 span in_use); 0x51fd = bytes the catching frame sits
// BELOW the scanned lo (the root-miss signature), emitted only when it does.
@[markused]
fn vgc_spchk_report(pkey voidptr, myframe usize) {
	cidx := C.vgc_get_cache_idx()
	if cidx < 0 || cidx >= 64 {
		return
	}
	C.vgc_say(0x51ee, u64(vgc_spchk_lo[cidx]))
	C.vgc_say(0x51ef, u64(vgc_spchk_hi[cidx]))
	C.vgc_say(0x51f0, u64(myframe))
	C.vgc_say(0x51f1, u64(vgc_heap.gc_cycle) - vgc_spchk_cyc[cidx])
	C.vgc_say(0x51f2, vgc_spchk_parked[cidx])
	C.vgc_say(0x51fa, vgc_is_allocated(pkey))
	C.vgc_say(0x51fb, u64(usize(pkey)))
	if myframe < vgc_spchk_lo[cidx] {
		C.vgc_say(0x51fd, u64(vgc_spchk_lo[cidx] - myframe))
	}
}

fn C.atoll(&char) i64
fn C.getenv(&char) &char

// vgc_init initializes the vgc heap: it fills the size-class tables, enables the
// collector and reads the `VGC_NEXT_GC_MB` environment override for the initial
// GC trigger. It is called once during runtime startup, before the first allocation.
@[markused]
pub fn vgc_init() {
	C.vgc_init_size_tables()
	vgc_heap.gc_enabled = 1
	vgc_heap.gc_percent = 100
	mb_env := C.getenv(c'VGC_NEXT_GC_MB')
	if mb_env != unsafe { nil } {
		mb := C.atoll(mb_env)
		if mb > 0 {
			vgc_base_floor = u64(mb) * 1024 * 1024
		}
	}
	pace_env := C.getenv(c'VGC_PACE')
	if pace_env != unsafe { nil } {
		// Explicit override of the on-by-default pacing: VGC_PACE=0 disables it,
		// any other value forces it on.
		vgc_pace_by_threads = C.atoll(pace_env) != 0
	}
	trace_env := C.getenv(c'VGC_GCTRACE')
	if trace_env != unsafe { nil } && C.atoll(trace_env) != 0 {
		vgc_gctrace = 1
	}
	pace_mb_env := C.getenv(c'VGC_PACE_MB')
	if pace_mb_env != unsafe { nil } {
		pmb := C.atoll(pace_mb_env)
		if pmb >= 0 {
			vgc_thread_headroom = u64(pmb) * 1024 * 1024
		}
	}
	// Soft limit: half the physical arena capacity by default, env-overridable.
	vgc_heap_soft_limit = u64(vgc_max_arenas) * u64(vgc_arena_size) / 2
	lim_env := C.getenv(c'VGC_MEMLIMIT_MB')
	if lim_env != unsafe { nil } {
		lmb := C.atoll(lim_env)
		if lmb > 0 {
			vgc_heap_soft_limit = u64(lmb) * 1024 * 1024
		}
	}
	vgc_heap.next_gc = vgc_base_floor // favor throughput over early collections
	vgc_heap.gc_phase = vgc_phase_off
	// NOTE: allspans is allocated LAZILY on the first vgc_span_alloc (under
	// vgc_heap.lock), not here — spans can be allocated during _vinit, BEFORE
	// vgc_init runs (the heap-init ordering quirk), so the registry must be brought
	// up by whoever adds the first span, not by vgc_init.
	// Register the main thread
	vgc_register_thread()
}

// ============================================================
// Thread registration (for root scanning)
// ============================================================

fn vgc_register_thread() {
	C.vgc_mutex_lock(&vgc_heap.cache_lock)
	// Reuse a reclaimed slot before growing the high-water mark, so that
	// churn (many short-lived threads) cannot exhaust the fixed cache array.
	mut idx := -1
	if vgc_heap.nfree_slots > 0 {
		vgc_heap.nfree_slots--
		idx = vgc_heap.free_slots[vgc_heap.nfree_slots]
	} else if vgc_heap.ncaches < vgc_max_threads {
		idx = vgc_heap.ncaches
		vgc_heap.ncaches = idx + 1
	}
	if idx < 0 {
		// Genuinely out of slots (>64 concurrent live threads). Leave this
		// thread unregistered rather than scribbling on caches[-1]; its
		// allocations fall through to vgc_ensure_registered retries.
		C.vgc_mutex_unlock(&vgc_heap.cache_lock)
		return
	}
	// Atomic bump (cache_lock serializes writers, but vgc_maybe_gc reads live_threads
	// LOCK-FREE for per-thread GC pacing — a plain RMW here races that atomic read).
	C.vgc_atomic_add_u32(&vgc_heap.live_threads, 1)

	// NOTE: cache_lock is held through the WHOLE slot setup below (clear, stack
	// bounds, mach_port, registered=true) and released only just before the
	// barrier. The collector holds cache_lock across its entire cycle, so this
	// guarantees it never observes a slot that is `registered=true` but was not
	// part of its suspend set — which would make vgc_scan_suspended_roots call
	// thread_regs on a RUNNING (un-suspended) thread and scan a wild stack range
	// (a rare collector-side segfault). With the lock held, a registering thread
	// is either fully registered before the collector takes the lock (so it is
	// suspended + scanned), or blocked here until the cycle ends (so it is skipped
	// while holding no heap objects but its in-flight spawn arg, which the
	// spawn-root registry keeps alive). No vgc allocation happens between lock and
	// unlock, so there is no re-entrant lock / deadlock.

	// A reused slot still holds the previous owner's span pointers; those
	// spans may have been swept/recycled. Clear the slot so the new thread
	// refills from central fresh.
	unsafe {
		for c in 0 .. 136 {
			vgc_heap.caches[idx].alloc[c] = nil
		}
		vgc_heap.caches[idx].tiny = 0
		vgc_heap.caches[idx].tiny_offset = 0
		vgc_heap.caches[idx].tiny_allocs = 0
		vgc_heap.caches[idx].stopped = 0
		vgc_heap.caches[idx].live_delta = 0
		vgc_heap.caches[idx].alloc_delta = 0
	}

	C.vgc_set_cache_idx(idx)
	// Arrange for vgc_thread_exit_cb(idx) to fire when this thread exits.
	C.vgc_install_thread_exit(idx)
	sp := usize(C.vgc_get_sp())
	mut stack_lo := usize(0)
	mut stack_hi := usize(0)
	mut stack_base := if sp > usize(8) * 1024 * 1024 {
		sp - usize(8) * 1024 * 1024
	} else {
		usize(0)
	}
	if C.vgc_get_stack_bounds(&stack_lo, &stack_hi) != 0 && stack_lo < stack_hi {
		dist_lo := if sp >= stack_lo { sp - stack_lo } else { stack_lo - sp }
		dist_hi := if stack_hi >= sp { stack_hi - sp } else { sp - stack_hi }
		stack_base = if dist_hi <= dist_lo { stack_hi } else { stack_lo }
	}
	unsafe {
		vgc_heap.caches[idx].registered = true
		vgc_heap.caches[idx].stack_base = stack_base
		vgc_heap.caches[idx].mach_port = C.vgc_thread_self_port() // for OS-level STW
	}
	vgc_refresh_stack_range_for_sp(idx, sp)
	C.vgc_trace(1, idx, u64(stack_base), u64(vgc_heap.caches[idx].mach_port)) // REG
	C.vgc_trace(2, idx, u64(C.vgc_atomic_load_u32(&vgc_heap.gc_phase)), 0) // BAR_IN

	// Slot is now fully registered and suspendable; release the registration gate
	// so the collector can proceed. The barrier (below) must NOT hold cache_lock.
	C.vgc_mutex_unlock(&vgc_heap.cache_lock)

	// Registration barrier (OS-suspend STW). A thread that registers DURING a
	// collection was not frozen by the suspend-all (it didn't exist yet); if it
	// allocated now it would create white objects the collector won't scan ->
	// swept while live. So wait until the current cycle finishes before doing
	// any allocation. It holds no heap objects yet, so waiting is safe. (Mark is
	// single-threaded, so no GC worker thread reaches here -> no deadlock.)
	for C.vgc_atomic_load_u32(&vgc_heap.gc_phase) != vgc_phase_off {
		C.vgc_atomic_fence()
	}
	C.vgc_trace(3, idx, 0, 0) // BAR_OUT
}

// vgc_thread_exit_cb is invoked (via a pthread-key destructor, see
// vgc_platform.h) when a registered thread exits. It marks the cache slot
// unregistered so stop-the-world no longer waits on a dead thread, and
// reclaims the slot for reuse. If a collection is mid-stop, the exiting
// thread counts as already-stopped (it has no more roots).
@[export: 'vgc_thread_exit_cb']
fn vgc_thread_exit_cb(idx int) {
	if idx < 0 || idx >= vgc_max_threads {
		return
	}
	C.vgc_trace(4, idx, 0, 0) // EXIT
	C.vgc_mutex_lock(&vgc_heap.cache_lock)
	if !vgc_heap.caches[idx].registered {
		C.vgc_mutex_unlock(&vgc_heap.cache_lock)
		return
	}
	unsafe {
		// Flush this thread's un-flushed per-thread accounting into the global
		// counters before the slot is released, so churn (frequent thread exit)
		// doesn't drift heap_live between GC rebaselines. Under cache_lock, which
		// the collector also holds across its cycle, so this is serialized.
		ld := vgc_heap.caches[idx].live_delta
		if ld >= 0 {
			C.vgc_atomic_add_u64(&vgc_heap.heap_live, u64(ld))
		} else {
			C.vgc_atomic_sub_u64(&vgc_heap.heap_live, u64(-ld))
		}
		C.vgc_atomic_add_u64(&vgc_heap.total_alloc, vgc_heap.caches[idx].alloc_delta)
		vgc_heap.caches[idx].live_delta = 0
		vgc_heap.caches[idx].alloc_delta = 0
		vgc_heap.caches[idx].registered = false
		vgc_heap.caches[idx].stack_lo = 0
		vgc_heap.caches[idx].stack_hi = 0
	}
	// Atomic decrement — see the bump in vgc_register_thread (lock-free PACE reader).
	if C.vgc_atomic_load_u32(&vgc_heap.live_threads) > 0 {
		C.vgc_atomic_sub_u32(&vgc_heap.live_threads, 1)
	}
	if vgc_heap.nfree_slots < vgc_max_threads {
		vgc_heap.free_slots[vgc_heap.nfree_slots] = idx
		vgc_heap.nfree_slots++
	}
	C.vgc_mutex_unlock(&vgc_heap.cache_lock)

	// NOTE: do NOT touch gc_stopped_count here. An exiting thread simply
	// stops being a live mutator (live_threads-- above); the collector's
	// wait loop recomputes its target from live_threads each iteration, so a
	// thread that exits during stop-the-world correctly drops out of the
	// target instead of being miscounted as "stopped" (which previously let
	// the collector proceed while a different live mutator was unscanned ->
	// use-after-free).
	C.vgc_set_cache_idx(-1)
}

// vgc_my_stack_base returns THIS thread's registered stack_base (the fixed stack
// top used to bound the conservative root scan), or 0 if unregistered. #145
// diagnostic: lets cx-private check whether a live stack object (e.g. the
// per-request env) actually falls within the scannable [sp, stack_base] range —
// if its address exceeds stack_base it is ABOVE the recorded top and never
// scanned (a stack-bounds root miss). markused so it is not DCE'd.
@[markused]
pub fn vgc_my_stack_base() usize {
	idx := C.vgc_get_cache_idx()
	if idx < 0 {
		return 0
	}
	return unsafe { vgc_heap.caches[idx].stack_base }
}

// vgc_my_stack_info returns THIS thread's (cache_idx, stack_lo, stack_hi) — the FULL
// registered scan bounds, or (-1,0,0) if unregistered. #58/#63 diagnostic: lets a
// concurrent [?worker] thread check whether its own live stack frame falls within the
// bounds vgc's STW root scan actually covers. idx<0 => unregistered (STW misses the whole
// stack); addr outside [lo,hi] => registered with WRONG bounds (mis-registration).
@[markused]
pub fn vgc_my_stack_info() (int, usize, usize) {
	idx := C.vgc_get_cache_idx()
	if idx < 0 {
		return -1, usize(0), usize(0)
	}
	return idx, unsafe { vgc_heap.caches[idx].stack_lo }, unsafe { vgc_heap.caches[idx].stack_hi }
}

fn vgc_ensure_registered() {
	if C.vgc_get_cache_idx() < 0 {
		vgc_register_thread()
	}
}

// vgc_spawn_root_add registers a thread-argument struct as a root for the
// create->start handoff window (see vgc_spawn_roots). Called by spawn codegen
// (gated -gc vgc) after the arg is filled and BEFORE pthread_create, while the
// spawning thread still holds the pointer on its (scanned) stack. If the table
// is momentarily full it spins until the array drains (never silently drops a
// root, which would reintroduce the swept-arg bug).
@[markused]
fn vgc_spawn_root_add(p voidptr) {
	if p == unsafe { nil } {
		return
	}
	for {
		C.vgc_mutex_lock(&vgc_spawn_root_lock)
		if vgc_nspawn_roots < vgc_max_spawn_roots {
			unsafe {
				vgc_spawn_roots[vgc_nspawn_roots] = p
			}
			vgc_nspawn_roots++
			C.vgc_mutex_unlock(&vgc_spawn_root_lock)
			return
		}
		C.vgc_mutex_unlock(&vgc_spawn_root_lock)
		// Full: a wrapper will release a slot shortly. Spin (rare; bounded by
		// in-flight spawns, themselves bounded by live threads).
		C.vgc_atomic_fence()
	}
}

// vgc_spawn_root_remove drops a registered thread-argument root. Called by the
// spawn wrapper once the arg has been consumed (just before freeing it). The
// child has by then dereferenced the arg and, if it allocated, registered its
// own stack as a root, so the arg's referents stay reachable without this entry.
@[markused]
fn vgc_spawn_root_remove(p voidptr) {
	if p == unsafe { nil } {
		return
	}
	C.vgc_mutex_lock(&vgc_spawn_root_lock)
	for i in 0 .. vgc_nspawn_roots {
		if vgc_spawn_roots[i] == p {
			// swap-remove with the last entry
			vgc_nspawn_roots--
			unsafe {
				vgc_spawn_roots[i] = vgc_spawn_roots[vgc_nspawn_roots]
				vgc_spawn_roots[vgc_nspawn_roots] = nil
			}
			break
		}
	}
	C.vgc_mutex_unlock(&vgc_spawn_root_lock)
}

fn vgc_refresh_stack_range() {
	cache_idx := C.vgc_get_cache_idx()
	if cache_idx < 0 {
		return
	}
	vgc_refresh_stack_range_for_sp(cache_idx, usize(C.vgc_get_sp()))
}

fn vgc_refresh_stack_range_for_sp(cache_idx int, sp usize) {
	if cache_idx < 0 || cache_idx >= vgc_max_threads {
		return
	}
	stack_base := unsafe { vgc_heap.caches[cache_idx].stack_base }
	if stack_base <= sp {
		unsafe {
			vgc_heap.caches[cache_idx].stack_lo = stack_base
			vgc_heap.caches[cache_idx].stack_hi = sp
		}
	} else {
		unsafe {
			vgc_heap.caches[cache_idx].stack_lo = sp
			vgc_heap.caches[cache_idx].stack_hi = stack_base
		}
	}
}

// ============================================================
// Span management (translated from Go's mspan operations)
// ============================================================

// Try to get a recycled span from the free list
fn vgc_get_free_span(npages u32) &VGC_Span {
	if npages == 0 || npages >= u32(vgc_max_pooled_pages) {
		return unsafe { nil }
	}
	C.vgc_mutex_lock(&vgc_heap.free_spans_lock)
	span := vgc_heap.free_spans[npages]
	if span != unsafe { nil } {
		unsafe {
			vgc_heap.free_spans[npages] = span.next
			span.next = nil
			span.prev = nil
			// in_use stays FALSE: it is set true only once the span is fully
			// (re)initialized (vgc_span_init / vgc_alloc_large). While in_use is false
			// the collector's clear-mark / count-marked / sweep loops skip the span, so
			// a mutator suspended mid-init can't have its half-built span touched. See
			// the in_use="fully initialized" invariant in vgc_span_init.
		}
		C.vgc_mutex_unlock(&vgc_heap.free_spans_lock)
		return span
	}
	C.vgc_mutex_unlock(&vgc_heap.free_spans_lock)
	return unsafe { nil }
}

// Return a fully-empty span to the free list for reuse
fn vgc_put_free_span(mut span VGC_Span) {
	npages := span.npages
	if npages == 0 || npages >= u32(vgc_max_pooled_pages) {
		return
	}
	// DIAGNOSTIC: did we just free the span holding the watched address?
	if vgc_watch_addr != 0 {
		span_end := span.base + usize(npages) * vgc_page_size
		if vgc_watch_addr >= span.base && vgc_watch_addr < span_end {
			vgc_watch_decommit = 1
		}
	}
	// KEEP the span's data pages committed (no decommit) for near-immediate reuse off
	// the free list. The previous design madvise-decommitted the data pages on every
	// pool, then page-faulted them back on every reuse; under the heavy span recycling
	// that correct reuse produces (~tens of thousands of spans/cycle) that per-span
	// syscall churn dominated wall-clock (≈190 s sys on g_churn 100 1 30). Bitmaps are
	// inline in the span (alloc_buf/mark_buf), so there is nothing to free here either.
	// Reuse is now pure pointer ops + a bitmap memset in vgc_span_init. RSS stays
	// bounded by the peak committed working set (heap goal floor + the sweep_gen
	// one-cycle grace), not the all-time allocation high-water.
	span.in_use = false
	span.class_idx = 0
	span.elem_size = 0
	span.nelems = 0
	span.alloc_count = 0
	span.free_index = 0
	// NO free_spans_lock here: vgc_put_free_span is collector-only (reached only via
	// vgc_sweep_span during a collection), and vgc_gc_start holds free_spans_lock
	// across the ENTIRE cycle (acquired before the world is stopped, so no mutator
	// is ever frozen mid-vgc_get_free_span holding it). Taking the lock here would
	// self-deadlock against that held lock. (The lock is NOT stolen/zeroed during
	// STW any more — stealing it let a frozen vgc_get_free_span resume into a
	// corrupted free list, handing out a span with a garbage base -> the object
	// zero-fill memset wrote to an unmapped page = the residual segv.)
	unsafe {
		span.next = vgc_heap.free_spans[npages]
		vgc_heap.free_spans[npages] = span
	}
}

// Allocate a VGC_Span descriptor from the bump slab. Caller MUST hold vgc_heap.lock.
// Descriptors are never individually freed (pooled via vgc_put_free_span), so a
// forever-growing bump slab is sound; this replaces a per-carve mmap() of ~one struct
// (a syscall under the heap lock) with a pointer bump + a rare bulk mmap.
@[inline]
fn vgc_alloc_span_meta() &VGC_Span {
	asz := (usize(sizeof(VGC_Span)) + 15) & ~usize(15)
	if vgc_heap.span_meta_cur == 0 || vgc_heap.span_meta_cur + asz > vgc_heap.span_meta_end {
		chunk := usize(1) * 1024 * 1024 // 1 MB slab ≈ thousands of descriptors per mmap
		csz := if asz > chunk { asz } else { chunk }
		mem := C.vgc_os_alloc(csz)
		if mem == unsafe { nil } {
			return unsafe { nil }
		}
		vgc_heap.span_meta_cur = usize(mem)
		vgc_heap.span_meta_end = usize(mem) + csz
	}
	p := vgc_heap.span_meta_cur
	vgc_heap.span_meta_cur += asz
	return unsafe { &VGC_Span(voidptr(p)) }
}

// Allocate a new span with the given number of pages
fn vgc_span_alloc(npages u32) &VGC_Span {
	// First try to reuse a free span
	recycled := vgc_get_free_span(npages)
	if recycled != unsafe { nil } {
		// Stamp the current GC cycle: a concurrent sweep must not reclaim this span as
		// "empty" (alloc_count 0) while it is in-flight to the mutator / mid-span_init.
		// See vgc_sweep_span's sweep_gen guard.
		unsafe {
			recycled.sweep_gen = u32(vgc_heap.gc_cycle)
		}
		return recycled
	}

	nbytes := usize(npages) * vgc_page_size

	C.vgc_mutex_lock(&vgc_heap.lock)
	// Try to find space in existing arenas
	mut base := usize(0)
	mut arena_idx := -1
	mut new_arena := false
	for i in 0 .. vgc_heap.narenas {
		a := unsafe { &vgc_heap.arenas[i] }
		if a.used + nbytes <= a.size {
			base = a.base + a.used
			arena_idx = i
			unsafe {
				vgc_heap.arenas[i].used += nbytes
			}
			break
		}
	}
	// Allocate new arena if needed
	if base == 0 {
		asize := if nbytes > vgc_arena_size { nbytes } else { vgc_arena_size }
		mem := C.vgc_os_alloc(asize)
		if mem == unsafe { nil } {
			C.vgc_mutex_unlock(&vgc_heap.lock)
			return unsafe { nil }
		}
		arena_idx = vgc_heap.narenas
		if arena_idx >= vgc_max_arenas {
			C.vgc_os_free(mem, asize)
			C.vgc_mutex_unlock(&vgc_heap.lock)
			return unsafe { nil }
		}
		unsafe {
			vgc_heap.arenas[arena_idx].base = usize(mem)
			vgc_heap.arenas[arena_idx].size = asize
			vgc_heap.arenas[arena_idx].used = nbytes
		}
		// narenas is NOT bumped here: it is the publication point for this whole
		// arena (base/size/used + the page_span map filled below) and must be
		// stored with RELEASE only after all of that is written — see the atomic
		// store just before the unlock. Bumping it here (a plain write, before the
		// page map existed) is the data race vgc_find_span hit.
		new_arena = true
		base = usize(mem)
		// Register in address map for O(1) lookup
		C.vgc_addr_map_register(usize(mem), asize, arena_idx)
		// Update global arena bounds for fast pointer rejection
		if vgc_arena_lo == 0 || base < vgc_arena_lo {
			vgc_arena_lo = base
		}
		arena_end := base + asize
		if arena_end > vgc_arena_hi {
			vgc_arena_hi = arena_end
		}
	}

	// Create span metadata from the bump slab (we hold vgc_heap.lock). Previously this
	// was a per-carve mmap() — a syscall under the heap lock that lengthened the hold
	// and drove new-span-carve contention under alloc-heavy [par] (B18).
	span := vgc_alloc_span_meta()
	if span == unsafe { nil } {
		C.vgc_mutex_unlock(&vgc_heap.lock)
		return unsafe { nil }
	}
	unsafe {
		C.memset(span, 0, sizeof(VGC_Span))
		span.base = base
		span.npages = npages
		// in_use stays FALSE until the span is fully initialized (vgc_span_init /
		// vgc_alloc_large set it true at the end). The collector skips !in_use spans,
		// so a span published in allspans below but still being initialized by a
		// (possibly suspended) mutator is never swept/cleared mid-build.
		// Stamp the current GC cycle so that even after in_use flips true, a sweep in
		// the same cycle won't reclaim it as empty before its first object is
		// allocated (alloc_count 0). See vgc_sweep_span's sweep_gen guard.
		span.sweep_gen = u32(vgc_heap.gc_cycle)
	}
	// Register span in arena's page map
	if arena_idx >= 0 {
		page_start := (base - vgc_heap.arenas[arena_idx].base) / vgc_page_size
		for p in 0 .. npages {
			pidx := page_start + p
			if pidx < vgc_pages_per_arena {
				// RELEASE-store the page_span slot (paired with the ACQUIRE load in
				// vgc_find_span). A span carved from an EXISTING arena does NOT bump
				// narenas, so the narenas release/acquire publication does not cover
				// these slot writes; without this, vgc_find_span (called lock-free by
				// vgc_free/vgc_realloc in the mutator hot path, concurrently with this
				// locked writer) races the plain store -> stale/garbage span -> heap
				// corruption (round-1 crash under concurrent HTTP teardown churn).
				unsafe {
					C.vgc_atomic_store_u64(&u64(voidptr(&vgc_heap.arenas[arena_idx].page_span[pidx])),
						u64(voidptr(span)))
				}
			}
		}
	}

	// Bring up the span registry on first use (we hold vgc_heap.lock here). mmap-backed
	// and lazily committed by the OS, so the reservation costs ~nothing until filled;
	// the pointer never moves, so the collector's lock-free allspans walks (incl. lazy
	// sweep outside STW) never see a relocated/freed buffer.
	if vgc_heap.allspans == unsafe { nil } {
		mut cap := 16 * 1024 * 1024 // 128 MB of address space; covers a multi-GB paced heap
		cap_env := C.getenv(c'VGC_ALLSPANS_CAP')
		if cap_env != unsafe { nil } {
			c := C.atoll(cap_env)
			if c > 0 {
				cap = int(c)
			}
		}
		vgc_heap.allspans = &&VGC_Span(C.vgc_os_alloc(usize(sizeof(voidptr)) * usize(cap)))
		vgc_heap.allspans_cap = cap
	}
	// Track in allspans. Exceeding the (mmap-reserved) capacity is NOT silently
	// ignored: an untracked span would never be marked/swept (leak) and never
	// recycled, so we fail loudly rather than corrupt the heap accounting. The cap is
	// large (16M entries default), so this only fires on a genuinely enormous heap —
	// the loud abort is kept as the backstop.
	if vgc_heap.nspans >= vgc_heap.allspans_cap {
		C.vgc_say(0xDEAD, u64(vgc_heap.nspans)) // span registry full — raise VGC_ALLSPANS_CAP
		C.vgc_mutex_unlock(&vgc_heap.lock)
		C.abort()
	}
	unsafe {
		vgc_heap.allspans[vgc_heap.nspans] = span
	}
	vgc_heap.nspans++

	// Publish a newly-added arena to the LOCK-FREE readers (vgc_find_span /
	// vgc_get_obj_size) with a RELEASE store, as the LAST write — after arenas[idx]
	// (base/size/used) AND its page_span map are fully written. Those readers load
	// narenas with ACQUIRE, so observing the bumped count guarantees they also
	// observe the fully-initialized arena + page map. Previously narenas was a plain
	// write bumped before the page map existed, so a concurrent lock-free reader
	// could see narenas grow and then read a stale base/size or a nil page_span ->
	// wrong/missing span -> heap corruption (TSan: data race on global vgc_heap,
	// vgc_find_span read vs vgc_span_alloc write; reproduced via concurrent HTTP
	// teardown churn, crashed in the request path). Doing it last also makes every
	// early-return above leave narenas consistent (the half-built arena is simply
	// never published).
	if new_arena {
		unsafe {
			C.vgc_atomic_store_u32(&u32(voidptr(&vgc_heap.narenas)), u32(arena_idx + 1))
		}
	}

	C.vgc_mutex_unlock(&vgc_heap.lock)
	return span
}

// Initialize a span for a specific size class
fn vgc_span_init(mut span VGC_Span, class_idx u8, noscan bool) {
	size := C.vgc_get_class_size(int(class_idx))
	npages := C.vgc_get_class_npages(int(class_idx))
	nobjs := C.vgc_get_class_nobjs(int(class_idx))

	span.class_idx = class_idx
	span.noscan = noscan
	span.elem_size = size
	span.npages = npages
	span.nelems = nobjs
	span.free_index = 0
	span.alloc_count = 0
	span.is_tiny = false // reset on (re)use; set true only when the tiny allocator carves a packed block
	span.dirty = 0       // concurrent mark: a recycled span starts clean

	// Bitmaps are inline in the span (alloc_buf/mark_buf); point the working pointers
	// at them and zero the bytes in use. nobjs <= 1024 -> bitmap_size <= 128 <= 136,
	// so the inline buffers always suffice. No allocation, no syscalls on reuse.
	bitmap_size := (nobjs + 7) / 8
	unsafe {
		span.alloc_bits = &span.alloc_buf[0]
		span.mark_bits = &span.mark_buf[0]
		C.memset(span.alloc_bits, 0, bitmap_size)
		C.memset(span.mark_bits, 0, bitmap_size)
	}
	// PUBLISH the span as live ONLY now that it is fully built (class/size/nelems +
	// zeroed bitmaps). in_use is the "fully initialized" flag: the collector's
	// clear-mark / count-marked / sweep all skip !in_use, so until this store a span
	// already in allspans (and a mutator possibly suspended right here) is invisible
	// to collection -> no half-built span is ever swept or cleared.
	span.in_use = true
}

// Find a free slot in a span and allocate it
// Alloc-black hook (concurrent mark only): a newly allocated object during the
// concurrent mark phase must have its mark bit set so the cycle's sweep does not
// reclaim it. It is marked BLACK (not enqueued): its bytes are zero-filled (no
// pointers to scan) or are filled by subsequent stores, each of which hits the
// write barrier. Atomic test_and_set because the collector may concurrently shade
// a different object sharing the same mark_bits byte. Compiled out (and the
// gc_phase load skipped) under the default build.
@[inline]
fn vgc_alloc_black_hook(span &VGC_Span, obj_idx u32) {
	$if vgc_concurrent ? {
		if C.vgc_atomic_load_u32(&vgc_heap.gc_phase) != vgc_phase_off {
			if span.mark_bits != unsafe { nil } {
				C.vgc_bitmap_test_and_set(span.mark_bits, obj_idx)
			}
		}
	}
}

fn vgc_span_alloc_obj(mut span VGC_Span) voidptr {
	if span.alloc_bits == unsafe { nil } {
		return unsafe { nil }
	}
	start_idx := span.free_index
	nbytes := (span.nelems + 7) >> 3
	start_byte := start_idx >> 3
	end_byte := (start_idx + 7) >> 3
	for pass in 0 .. 2 {
		mut byte_idx := if pass == 0 { start_byte } else { u32(0) }
		limit := if pass == 0 { nbytes } else { end_byte }
		for byte_idx < limit {
			bit_base := byte_idx << 3
			mut b := unsafe { span.alloc_bits[byte_idx] }
			if b == 0xFF {
				byte_idx++
				continue
			}
			// start_idx is only a search HINT: pass 0 begins at the start byte's
			// start_bit to skip already-allocated low slots. Pass 1 is the wrap-around
			// that re-covers [0, start_byte]; it MUST scan the start byte from bit 0,
			// else bits [0, start_bit) of the start byte are scanned in NEITHER pass.
			// A span whose free_index points past a still-free low slot (e.g. a stale
			// free_index vs a concurrent cross-thread free) would then report "full"
			// with room left -> vgc_span_alloc_obj nil -> vgc_malloc nil -> &T{} NULL
			// -> caller null-deref. Single-byte spans (small nelems) hit this whenever
			// free_index == nelems. The `pass == 0 &&` guard closes it.
			start_bit := if pass == 0 && byte_idx == start_byte { start_idx & 7 } else { u32(0) }
			for bit := start_bit; bit < u32(8); bit++ {
				i := bit_base + bit
				if i >= span.nelems {
					break
				}
				mask := u8(1) << bit
				if (b & mask) == 0 {
					// Atomically claim this slot. The set must be an atomic OR (not a
					// plain RMW of the byte): a concurrent cross-thread vgc_free clears
					// another bit in the SAME byte under central[class].lock, which this
					// lock-free mcache fast path does not hold. With both sides atomic
					// (OR here, AND in vgc_free) neither loses the other's update.
					old := unsafe {
						C.vgc_atomic_fetch_or_u8(&u8(voidptr(usize(span.alloc_bits) + usize(byte_idx))),
							mask)
					}
					if (old & mask) != 0 {
						// Lost the slot to a racer (defensive; normally only the owning
						// thread sets bits in its mcache span). Keep scanning.
						continue
					}
					unsafe { C.vgc_atomic_add_u32(&u32(voidptr(&span.alloc_count)), 1) }
					span.free_index = i + 1 // hint only; a stale value is still correct
					vgc_alloc_black_hook(span, i) // concurrent mark: alloc-black
					addr := span.base + usize(i) * usize(span.elem_size)
					$if vgc_birthcheck ? {
						// #58 forensic: the atomic OR above just claimed this bit; a
						// clear read-back means something is clobbering this span's
						// alloc bitmap out from under us (0xa110 = born-dead). Also
						// register victim-class births (ptr + gc cycle) so DEAD-KEYS
						// can report the birth→dead-read cycle delta: delta==0 with
						// no explicit free = a wild bitmap clear.
						if C.vgc_bitmap_get(span.alloc_bits, i) == 0 {
							C.vgc_say(0xa110, u64(addr))
						}
						if !span.noscan && span.elem_size >= u32(128)
							&& span.elem_size <= u32(192) {
							vgc_birth_record(addr)
						}
					}
					return unsafe { voidptr(addr) }
				}
			}
			byte_idx++
		}
	}
	return unsafe { nil } // span is full
}

// ============================================================
// Central free list operations (translated from Go's mcentral)
// ============================================================

// Get a span with free objects for the given span class
fn vgc_central_get_span(span_class int) &VGC_Span {
	central := unsafe { &vgc_heap.central[span_class] }
	C.vgc_mutex_lock(&central.lock)

	// Try partial list first (spans with free objects)
	mut span := central.partial
	if span != unsafe { nil } {
		// Remove from partial list
		unsafe {
			vgc_heap.central[span_class].partial = span.next
		}
		if span.next != unsafe { nil } {
			unsafe {
				span.next.prev = nil
			}
		}
		unsafe {
			span.next = nil
			span.prev = nil
			span.on_central = 0 // popped off the central list; now owned by a mcache
			// Mark as acquired THIS cycle so a concurrent sweep won't reclaim it as
			// empty while it is in-flight to the mutator (see vgc_sweep_span guard).
			span.sweep_gen = u32(vgc_heap.gc_cycle)
		}
		C.vgc_mutex_unlock(&central.lock)
		return span
	}

	C.vgc_mutex_unlock(&central.lock)

	// No spans available - allocate a new one
	class_idx := u8(span_class / 2)
	noscan := (span_class % 2) == 1
	npages := C.vgc_get_class_npages(int(class_idx))
	new_span := vgc_span_alloc(npages)
	if new_span == unsafe { nil } {
		return unsafe { nil }
	}
	unsafe {
		vgc_span_init(mut new_span, class_idx, noscan)
	}
	// (vgc_span_alloc already stamped new_span.sweep_gen = gc_cycle before publishing
	// it in allspans; span_init does not touch sweep_gen, so it is still protected.)

	return new_span
}

// Return a span to the central free list
fn vgc_central_return_span(span_class int, mut span VGC_Span) {
	central := unsafe { &vgc_heap.central[span_class] }
	C.vgc_mutex_lock(&central.lock)

	if span.alloc_count < span.nelems {
		// Has free objects - add to partial
		unsafe {
			span.next = vgc_heap.central[span_class].partial
			span.prev = nil
		}
		if span.next != unsafe { nil } {
			unsafe {
				span.next.prev = span
			}
		}
		unsafe {
			vgc_heap.central[span_class].partial = span
			span.on_central = 1 // on the partial list
		}
	} else {
		// Full - add to full list
		unsafe {
			span.next = vgc_heap.central[span_class].full
			span.prev = nil
		}
		if span.next != unsafe { nil } {
			unsafe {
				span.next.prev = span
			}
		}
		unsafe {
			vgc_heap.central[span_class].full = span
			span.on_central = 2 // on the full list
		}
	}

	C.vgc_mutex_unlock(&central.lock)
}

// ============================================================
// Cache operations (translated from Go's mcache)
// ============================================================

fn vgc_cache_get_span(cache_idx int, span_class int) &VGC_Span {
	if cache_idx < 0 {
		// Unregistered thread: the fixed [vgc_max_threads] cache table is exhausted
		// (e.g. >64 concurrent `go` threads — vgc_register_thread leaves idx = -1
		// rather than scribble on caches[-1]). It has no per-thread mcache slot, so
		// allocate straight from central (vgc_central_get_span is internally locked).
		// No caching: each call gets its own span; partial spans are reclaimed by the
		// collector. Slower for these overflow threads, but SAFE — previously this
		// indexed caches[-1] -> "fixed array index out of range (index: -1, len: 64)"
		// -> panic, and the panic's own message formatting re-entered malloc -> the
		// same crash (infinite recursion).
		return vgc_central_get_span(span_class)
	}
	span := unsafe { vgc_heap.caches[cache_idx].alloc[span_class] }
	if span != unsafe { nil } {
		// Check if span has free objects
		if span.alloc_count < span.nelems {
			return span
		}
		// Span is full — DROP it instead of returning it to central.full (B18). The
		// partial list is never reused (vgc_central_return_span only lands FULL spans on
		// full; sweep relinks only fully-empty), so the per-fill return was pure
		// central[].lock contention — a top serializer of alloc-heavy [par]. The dropped
		// span stays in allspans, is marked/swept normally, and is reclaimed when empty
		// via the on_central==0 path in vgc_sweep_span. SOUND: it is no longer referenced
		// by this mcache (alloc[span_class] is overwritten below) nor by any mutator
		// local, so same-cycle reclaim is correct (this is NOT the residual-#4 case,
		// which was a span STILL mcache-resident); while still referenced here it is
		// protected by vgc_protect_cached_spans' sweep_gen stamp.
	}
	// Get fresh span from central (reuses central.partial if a sweep populated it, else
	// carves a new span under vgc_heap.lock).
	new_span := vgc_central_get_span(span_class)
	unsafe {
		vgc_heap.caches[cache_idx].alloc[span_class] = new_span
	}
	return new_span
}

// ============================================================
// Main allocation entry points
// (translated from Go's runtime.mallocgc)
// ============================================================

fn vgc_malloc(n usize) voidptr {
	return vgc_malloc_typed_opts(n, 0, 0, true)
}

// vgc_malloc_typed allocates with a precise pointer map.
// ptrmap: bitmap where bit N means word offset N is a pointer.
// ptr_words: number of pointer words in the object.
// If ptrmap==0 && ptr_words==0, falls back to conservative scanning.
fn vgc_malloc_typed(n usize, ptrmap u64, ptr_words u8) voidptr {
	return vgc_malloc_typed_opts(n, ptrmap, ptr_words, true)
}

fn vgc_malloc_typed_opts(n usize, ptrmap u64, ptr_words u8, zero_fill bool) voidptr {
	$if vgc_coarse_alloc ? {
		relock := C.vgc_alloc_try_enter() != 0
		if relock {
			C.vgc_mutex_lock(&vgc_alloc_lock)
		}
		defer {
			if relock {
				C.vgc_mutex_unlock(&vgc_alloc_lock)
				C.vgc_alloc_exit()
			}
		}
	}
	if n == 0 {
		return unsafe { nil }
	}

	vgc_ensure_registered()
	cache_idx := C.vgc_get_cache_idx()

	// Large allocation (> 32KB) - get dedicated span
	if n > usize(vgc_max_small_size) {
		vgc_maybe_gc()
		return vgc_alloc_large(n, false, zero_fill)
	}

	// Small allocation - use size class and cache
	class_idx := C.vgc_size_class(u32(n))
	if class_idx == 0 {
		vgc_maybe_gc()
		return vgc_alloc_large(n, false, zero_fill)
	}

	span_class := int(class_idx) * 2 // scan variant
	mut span := vgc_cache_get_span(cache_idx, span_class)
	if span == unsafe { nil } {
		// Out of span space: the pacer is heap_live-driven, so under thread-churn
		// (wave threads exit leaving dead spans the pacer hasn't collected yet)
		// the arenas can physically exhaust before next_gc is hit. Returning nil
		// here would make `&T{}` NULL -> the caller's null deref (the residual
		// thread-churn segv). Instead force a full collection (sweeps dead objects
		// + recycles emptied spans to free_spans) and retry before giving up.
		// Mirrors Go's mallocgc growth-on-exhaustion. (vgc_cache_get_span released
		// vgc_heap.lock before returning, so no lock is held here.)
		span = vgc_collect_and_retry_span(cache_idx, span_class)
		if span == unsafe { nil } {
			return unsafe { nil } // genuine OOM after reclaim
		}
	}

	// Precise per-span ptrmap scanning was REMOVED as unsound: a span serves one
	// size CLASS but holds many different TYPES (and conservative ptrmap==0
	// allocations), so a single per-span ptrmap mis-describes most objects and the
	// mark phase skips their live pointers (see vgc_drain_mark_work). The mark phase
	// now scans scannable spans conservatively, so this hint is unused; leave it
	// unset (has_ptrmap stays false) to avoid resurrecting the unsound path.
	_ = ptrmap
	_ = ptr_words

	ptr := unsafe { vgc_span_alloc_obj(mut span) }
	if ptr != unsafe { nil } {
		// Track actual object bytes, not page bytes (per-thread; see vgc_acct_alloc)
		vgc_acct_alloc(cache_idx, u64(span.elem_size), u64(n))
		if zero_fill {
			unsafe { C.memset(ptr, 0, n) }
		}
		// Periodic GC check - only when span fills up (amortize cost)
		if span.alloc_count >= span.nelems {
			vgc_maybe_gc()
		}
	}
	return ptr
}

// Force a full STW collection NOW (regardless of the pacer), routed through the
// register-spilling trampoline so this thread's roots (held only in callee-saved
// regs, e.g. the `last` local) are scanned. If a collection is already running,
// vgc_gc_start's phase CAS makes this a no-op; the caller's retry loop then either
// benefits from that concurrent cycle or forces another.
fn vgc_force_collect() {
	ci := C.vgc_get_cache_idx()
	if ci >= 0 {
		unsafe {
			C.vgc_run_gc_spilled(&vgc_heap.caches[ci].stack_lo, &vgc_heap.caches[ci].stack_hi,
				vgc_heap.caches[ci].stack_base)
		}
	} else {
		vgc_gc_start()
	}
}

// Span-allocation failed (arenas physically exhausted while the heap_live-driven
// pacer had not yet triggered). Reclaim and retry before reporting OOM: a full
// collection sweeps dead objects and recycles emptied spans back to free_spans,
// which the retried vgc_cache_get_span -> vgc_span_alloc -> vgc_get_free_span then
// reuses. Bounded retries so a genuine OOM still terminates.
@[markused]
fn vgc_collect_and_retry_span(cache_idx int, span_class int) &VGC_Span {
	for _ in 0 .. 8 {
		vgc_force_collect()
		// If another thread won the collector CAS, our force was a no-op; wait for
		// that in-progress cycle to finish (it frees the space we need) before
		// retrying, so concurrent exhausting allocators don't burn all retries
		// spinning while a collection is mid-flight. (If WE collected, phase is
		// already off here. A mach-suspend by the active collector freezes us
		// safely mid-wait — same pattern as the registration barrier.)
		for C.vgc_atomic_load_u32(&vgc_heap.gc_phase) != vgc_phase_off {
			C.vgc_atomic_fence()
		}
		span := vgc_cache_get_span(cache_idx, span_class)
		if span != unsafe { nil } {
			return span
		}
	}
	return unsafe { nil } // genuine OOM after reclaim
}

// Per-thread heap-accounting flush threshold: a thread folds its private
// live_delta/alloc_delta into the global counters once its net work crosses this
// many bytes. Bounds global-counter staleness to ~vgc_acct_flush * nthreads while
// keeping the alloc/free fast path off the shared cacheline. 1 MB is well under
// the 256 MB GC goal, so the pacer trigger lags negligibly.
const vgc_acct_flush = u64(1) << 20

// Hot-path allocation accounting. Bumps THIS thread's private deltas; flushes to
// the global heap_live/total_alloc only every ~vgc_acct_flush of total alloc (so
// it flushes periodically even when live_delta oscillates near zero under balanced
// alloc/free). cache_idx is the caller's own slot, so the writes are race-free.
@[inline]
fn vgc_acct_alloc(cache_idx int, live_sz u64, total_n u64) {
	if cache_idx < 0 {
		// Unregistered (overflow) thread: no per-thread accounting slot — fold the
		// bytes straight into the global atomics (mirrors vgc_acct_free's idx<0 path).
		// Without this, caches[-1] is an out-of-range fixed-array index -> panic.
		C.vgc_atomic_add_u64(&vgc_heap.heap_live, live_sz)
		C.vgc_atomic_add_u64(&vgc_heap.total_alloc, total_n)
		return
	}
	unsafe {
		vgc_heap.caches[cache_idx].live_delta += i64(live_sz)
		vgc_heap.caches[cache_idx].alloc_delta += total_n
		if vgc_heap.caches[cache_idx].alloc_delta >= vgc_acct_flush {
			ld := vgc_heap.caches[cache_idx].live_delta
			if ld >= 0 {
				C.vgc_atomic_add_u64(&vgc_heap.heap_live, u64(ld))
			} else {
				C.vgc_atomic_sub_u64(&vgc_heap.heap_live, u64(-ld))
			}
			C.vgc_atomic_add_u64(&vgc_heap.total_alloc, vgc_heap.caches[cache_idx].alloc_delta)
			vgc_heap.caches[cache_idx].live_delta = 0
			vgc_heap.caches[cache_idx].alloc_delta = 0
		}
	}
}

// Hot-path free accounting. Decrements the CALLING thread's private live_delta
// (a cross-thread free legitimately drives this negative; the global stays correct
// after aggregation). Falls back to the global atomic for an unregistered thread.
@[inline]
fn vgc_acct_free(sz u64) {
	idx := C.vgc_get_cache_idx()
	if idx < 0 {
		C.vgc_atomic_sub_u64(&vgc_heap.heap_live, sz)
		return
	}
	unsafe {
		vgc_heap.caches[idx].live_delta -= i64(sz)
		if vgc_heap.caches[idx].live_delta <= -i64(vgc_acct_flush) {
			C.vgc_atomic_sub_u64(&vgc_heap.heap_live, u64(-vgc_heap.caches[idx].live_delta))
			vgc_heap.caches[idx].live_delta = 0
		}
	}
}

// Amortized GC trigger check - avoids atomic loads on every allocation
fn vgc_maybe_gc() {
	C.vgc_trace(21, C.vgc_get_cache_idx(), C.vgc_atomic_load_u64(&vgc_heap.heap_live),
		u64(C.vgc_atomic_load_u32(&vgc_heap.gc_enabled))) // MAYBE_GC entry (diagnostic, pre-gate)
	if C.vgc_atomic_load_u32(&vgc_heap.gc_enabled) != 0 {
		heap_live := C.vgc_atomic_load_u64(&vgc_heap.heap_live)
		mut next_gc := C.vgc_atomic_load_u64(&vgc_heap.next_gc)
		if vgc_pace_by_threads {
			// Per-thread pacing: give the heap N mutators' worth of ADDITIVE
			// allocation headroom so N concurrent allocators don't trip the shared
			// trigger N x more often per unit of per-thread progress. Additive (not
			// the former `next_gc *= lt` multiplier) and clamped to the soft heap
			// limit, so the goal can never outrun the arena capacity — the pacer
			// must stay alive on many-threaded servers (#57/#71 field OOM).
			lt := C.vgc_atomic_load_u32(&vgc_heap.live_threads)
			if lt > 1 {
				next_gc += u64(lt - 1) * vgc_thread_headroom
			}
		}
		if next_gc > vgc_heap_soft_limit {
			next_gc = vgc_heap_soft_limit
		}
		C.vgc_trace(20, C.vgc_get_cache_idx(), heap_live, next_gc) // PACE (diagnostic)
		if heap_live >= next_gc {
			// Run the collection through a trampoline that spills THIS
			// (collector) thread's callee-saved registers into the scanned
			// range, so a mutator root held only in a register (e.g. `last`
			// in the loop that triggered the GC) is not missed.
			ci := C.vgc_get_cache_idx()
			if ci >= 0 {
				unsafe {
					C.vgc_run_gc_spilled(&vgc_heap.caches[ci].stack_lo,
						&vgc_heap.caches[ci].stack_hi, vgc_heap.caches[ci].stack_base)
				}
			} else {
				vgc_gc_start()
			}
		}
		if C.vgc_atomic_load_u32(&vgc_heap.gc_stop_flag) != 0 {
			vgc_safepoint()
		}
	}
	// NOTE: GC-assist (a mutator draining a proportional slice of the grey set when it
	// allocates during the concurrent mark) is DELIBERATELY NOT wired here. It is
	// UNSOUND under this collector's preemptive mach-suspend: an assisting mutator that
	// pops a grey object and is then mach-suspended MID-SCAN orphans that object (it is
	// already off the queue, so the collector never scans its referents -> they are
	// swept while live). Verified: enabling it corrupted g_churn (thousands of events)
	// and cm_stress, and segfaulted. A sound assist needs cooperative safepoints for the
	// assist scan (so a mutator is never frozen mid-scan) or popped-object tracking —
	// substantial, deferred. Without assist the concurrent mark is correct; the heap can
	// overshoot the goal during a long mark, bounded by the existing span-exhaustion ->
	// vgc_collect_and_retry_span (force-collect) safety net. See CONCURRENT-MARK-FINDINGS.md.
}

fn vgc_malloc_noscan(n usize) voidptr {
	return vgc_malloc_noscan_opts(n, true)
}

fn vgc_malloc_noscan_opts(n usize, zero_fill bool) voidptr {
	$if vgc_coarse_alloc ? {
		relock := C.vgc_alloc_try_enter() != 0
		if relock {
			C.vgc_mutex_lock(&vgc_alloc_lock)
		}
		defer {
			if relock {
				C.vgc_mutex_unlock(&vgc_alloc_lock)
				C.vgc_alloc_exit()
			}
		}
	}
	if n == 0 {
		return unsafe { nil }
	}

	vgc_ensure_registered()
	cache_idx := C.vgc_get_cache_idx()

	if n > usize(vgc_max_small_size) {
		vgc_maybe_gc()
		return vgc_alloc_large(n, true, zero_fill)
	}

	class_idx := C.vgc_size_class(u32(n))
	if class_idx == 0 {
		return vgc_alloc_large(n, true, zero_fill)
	}

	// Tiny allocator for very small objects (translated from Go's mcache tiny allocator)
	if n < vgc_tiny_size && cache_idx >= 0 {
		cache := unsafe { &vgc_heap.caches[cache_idx] }
		if cache.tiny != 0 {
			// Align up for the allocation
			mut off := cache.tiny_offset
			if n >= 8 {
				off = (off + 7) & ~usize(7)
			} else if n >= 4 {
				off = (off + 3) & ~usize(3)
			} else if n >= 2 {
				off = (off + 1) & ~usize(1)
			}
			if off + n <= vgc_tiny_size {
				ptr := unsafe { voidptr(cache.tiny + off) }
				unsafe {
					vgc_heap.caches[cache_idx].tiny_offset = off + n
					vgc_heap.caches[cache_idx].tiny_allocs++
				}
				// tiny-block reuse: bytes already counted live at span alloc, so
				// only the total-alloc stat is bumped (per-thread).
				vgc_acct_alloc(cache_idx, 0, u64(n))
				return ptr
			}
		}
		// Allocate a new tiny block
		span_class := int(class_idx) * 2 + 1 // noscan
		span := vgc_cache_get_span(cache_idx, span_class)
		if span != unsafe { nil } {
			ptr := unsafe { vgc_span_alloc_obj(mut span) }
			if ptr != unsafe { nil } {
				if zero_fill {
					unsafe { C.memset(ptr, 0, usize(span.elem_size)) }
				} else {
					$if vgc_verify ? {
						unsafe { C.memset(ptr, 0, usize(span.elem_size)) } // DEBUG: clean verifier signal (see non-tiny path)
					}
					$if vgc_closonly ? {
						unsafe { C.memset(ptr, 0, usize(span.elem_size)) } // #145: clean closure-check signal (stale-tail FP)
					}
				}
				unsafe {
					// Mark the span as tiny-packed: this slot will hold several
					// independently-allocated sub-objects, so vgc_free must never
					// reclaim it on an individual free (it would clobber live
					// siblings). Only the tracing collector reclaims tiny blocks.
					span.is_tiny = true
					vgc_heap.caches[cache_idx].tiny = usize(ptr)
					vgc_heap.caches[cache_idx].tiny_offset = n
					vgc_heap.caches[cache_idx].tiny_allocs++
				}
				vgc_acct_alloc(cache_idx, u64(span.elem_size), u64(n))
				return ptr
			}
		}
	}

	span_class := int(class_idx) * 2 + 1 // noscan variant
	mut span := vgc_cache_get_span(cache_idx, span_class)
	if span == unsafe { nil } {
		// Out of span space — reclaim + retry before OOM (see the scan-path note
		// in vgc_malloc_typed_opts). Without this, a churn-time exhaustion makes
		// the array/buffer alloc NULL -> caller null deref (the residual segv).
		span = vgc_collect_and_retry_span(cache_idx, span_class)
		if span == unsafe { nil } {
			return unsafe { nil }
		}
	}

	ptr := unsafe { vgc_span_alloc_obj(mut span) }
	if ptr != unsafe { nil } {
		vgc_acct_alloc(cache_idx, u64(span.elem_size), u64(n))
		if zero_fill {
			unsafe { C.memset(ptr, 0, n) }
		}
		$if vgc_verify ? {
			// DEBUG-ONLY: zero the FULL slot (not just n) so the mark-closure
			// verifier never mistakes a noscan slot's stale tail bytes for a live
			// pointer. The real collector never scans noscan spans, so this has no
			// production effect — it only cleans the verifier's signal.
			unsafe { C.memset(ptr, 0, usize(span.elem_size)) }
		}
		$if vgc_closonly ? {
			// #145 deep-fix A: same full-slot clean as vgc_verify, so cx_closonly_det's
			// closure check is not fooled by stale-tail bytes in a recycled noscan slot
			// (the suspected false-positive source). DEBUG-only; default build unaffected.
			unsafe { C.memset(ptr, 0, usize(span.elem_size)) }
		}
	}
	return ptr
}

// Allocate a large object (> 32KB) with its own span
fn vgc_alloc_large(n usize, noscan bool, zero_fill bool) voidptr {
	npages := u32((n + vgc_page_size - 1) / vgc_page_size)
	mut span := vgc_span_alloc(npages)
	if span == unsafe { nil } {
		// Reclaim + retry before OOM (see vgc_collect_and_retry_span).
		// MUST mirror vgc_collect_and_retry_span: after force_collect, WAIT for any
		// in-flight collection to finish before retrying. vgc_force_collect no-ops when
		// another thread already holds the collector (vgc_gc_start CAS-fails and returns
		// immediately if gc_phase != off). Without the wait, N concurrent large
		// allocators that hit arena exhaustion at once burn all 8 retries spinning on a
		// still-full heap WHILE the one winning collector is mid-sweep, then spuriously
		// return nil — the caller NULL-derefs or memory_panics even though the collection
		// is about to free the spans they need. (cx-private #57: multi-mutator
		// HTTP-reactor OOM-panic. The small-object path already waits; the large path did
		// not — this closes that asymmetry. Single-threaded is unaffected: no contender,
		// so gc_phase is already off after our own force_collect.)
		for _ in 0 .. 8 {
			vgc_force_collect()
			for C.vgc_atomic_load_u32(&vgc_heap.gc_phase) != vgc_phase_off {
				C.vgc_atomic_fence()
			}
			span = vgc_span_alloc(npages)
			if span != unsafe { nil } {
				break
			}
		}
		if span == unsafe { nil } {
			return unsafe { nil }
		}
	}

	unsafe {
		span.class_idx = 0
		span.noscan = noscan
		span.is_tiny = false // large spans are never tiny-packed (reset in case of a recycled span)
		span.dirty = 0       // concurrent mark: recycled large span starts clean
		span.elem_size = u32(n)
		span.nelems = 1
		span.alloc_count = 1

		// Single-element bitmap, inline in the span (see VGC_Span.alloc_buf/mark_buf).
		span.alloc_bits = &span.alloc_buf[0]
		span.mark_bits = &span.mark_buf[0]
		span.alloc_bits[0] = 1
		span.mark_bits[0] = 0
		vgc_alloc_black_hook(span, 0) // concurrent mark: alloc-black this large object
		// Fully initialized -> publish as live (see the in_use invariant in
		// vgc_span_init; span_alloc/get_free_span leave in_use false until here).
		span.in_use = true
	}
	// Add to large allocation list
	C.vgc_mutex_lock(&vgc_heap.lock)
	unsafe {
		span.next = vgc_heap.large_alloc
		vgc_heap.large_alloc = span
	}
	C.vgc_mutex_unlock(&vgc_heap.lock)

	C.vgc_atomic_add_u64(&vgc_heap.heap_live, u64(n))
	C.vgc_atomic_add_u64(&vgc_heap.total_alloc, u64(n))

	ptr := unsafe { voidptr(span.base) }
	if zero_fill {
		unsafe { C.memset(ptr, 0, n) }
	}
	return ptr
}

// Realloc for VGC-managed memory
fn vgc_realloc(old_ptr voidptr, new_size usize) voidptr {
	$if vgc_coarse_alloc ? {
		relock := C.vgc_alloc_try_enter() != 0
		if relock {
			C.vgc_mutex_lock(&vgc_alloc_lock)
		}
		defer {
			if relock {
				C.vgc_mutex_unlock(&vgc_alloc_lock)
				C.vgc_alloc_exit()
			}
		}
	}
	if old_ptr == unsafe { nil } {
		return vgc_malloc(new_size)
	}
	if new_size == 0 {
		return unsafe { nil }
	}
	// Find the span owning this pointer to get old size
	old_span := vgc_find_span(old_ptr)
	if old_span == unsafe { nil } {
		// Unknown object - just malloc new
		return vgc_malloc(new_size)
	}
	old_size := usize(old_span.elem_size)
	if new_size <= old_size {
		return old_ptr // fits in current allocation
	}
	// Preserve the original scan policy so raw buffers do not become scan objects.
	mut new_ptr := unsafe { nil }
	if old_span.noscan {
		new_ptr = vgc_malloc_noscan_opts(new_size, false)
	} else if old_span.has_ptrmap {
		new_ptr = vgc_malloc_typed_opts(new_size, old_span.ptrmap, old_span.ptr_words, false)
	} else {
		new_ptr = vgc_malloc_typed_opts(new_size, 0, 0, false)
	}
	if new_ptr != unsafe { nil } {
		copy_size := if old_size < new_size { old_size } else { new_size }
		// Concurrent-mark barrier: this memcpy moves the old buffer's bytes (which may
		// hold pointers) into the fresh (alloc-black) buffer with no codegen-visible
		// store, so dirty the destination span before the copy. Catch-all for every
		// realloc-based grow (array ensure_cap via realloc, map DenseArray.expand,
		// string builders, ...). new_ptr is scannable here (noscan path skips dirty).
		$if vgc_concurrent ? {
			vgc_wb_store(new_ptr)
		}
		unsafe { C.memcpy(new_ptr, old_ptr, copy_size) }
	}
	return new_ptr
}

// Free is mostly a no-op for GC, but can hint at deallocation
fn vgc_free(ptr voidptr) {
	$if vgc_coarse_alloc ? {
		relock := C.vgc_alloc_try_enter() != 0
		if relock {
			C.vgc_mutex_lock(&vgc_alloc_lock)
		}
		defer {
			if relock {
				C.vgc_mutex_unlock(&vgc_alloc_lock)
				C.vgc_alloc_exit()
			}
		}
	}
	if ptr == unsafe { nil } {
		return
	}
	// In a GC environment, explicit free is optional.
	// The object will be collected if unreachable.
	// However, we can mark it as free immediately for reuse.
	span := vgc_find_span(ptr)
	if span == unsafe { nil } {
		return
	}
	if span.elem_size == 0 {
		return
	}
	// TINY-BLOCK SAFETY: the tiny allocator (vgc_malloc_noscan_opts) packs several
	// independently-allocated sub-objects (each < vgc_tiny_size) into a SINGLE span
	// slot, Go-style. A tiny-packed slot is therefore NOT solely owned by the object
	// whose pointer was passed here: `obj_idx` below maps every packed sub-object
	// (and any interior pointer) to the same slot, so honoring this free would clear
	// the alloc bit for the whole slot and let a later allocation reuse it while
	// sibling sub-objects are still live -> their bytes get overwritten. (Observed as
	// map corruption: a map's `delete` frees one short string key's char buffer,
	// which shares a tiny block with other live keys.) Like Go, tiny objects are
	// never reclaimed by an individual free; only the tracing collector reclaims a
	// tiny block, and only once NONE of its packed sub-objects is reachable. So skip
	// the eager-free hint for any span the tiny allocator carved from.
	if span.is_tiny {
		return
	}
	obj_idx := u32((usize(ptr) - span.base) / usize(span.elem_size))
	// Serialize the span-metadata mutation (alloc_bits / alloc_count / free_index)
	// under the per-size-class central lock — the SAME lock the allocator
	// (vgc_central_get_span / vgc_central_return_span) takes when it moves spans of
	// this class between the partial/full lists and reads their alloc_count, and the
	// SAME lock the collector pre-acquires (for ALL 136 classes) before stopping the
	// world. Without it, an eager Perceus free racing a concurrent allocation of the
	// same class can interleave the bitmap clear / count decrement with the
	// allocator's reads -> a corrupt alloc_count or a doubly-handed-out slot. It was
	// only latent because Perceus frees are rare and the front line is thread-local.
	// This obeys the lock-before-suspend discipline: the hold is brief and does NO
	// allocation / blocking / safepoint (vgc_acct_free is lock-free), so a mutator
	// frozen here releases promptly and the collector — which acquires every central
	// lock while mutators still run, then never re-enters them — cannot deadlock.
	span_class := int(span.class_idx) * 2 + (if span.noscan { 1 } else { 0 })
	if span_class < 0 || span_class >= 136 {
		return
	}
	if obj_idx >= span.nelems || span.alloc_bits == unsafe { nil } {
		return
	}
	// B19 free-path scaling: a span that is NOT on a central partial/full list
	// (on_central == 0 — i.e. resident in a thread mcache, or dropped and awaiting
	// sweep) has no central-list membership to guard, and its bitmap + count mutations
	// are each individually atomic, so the per-class central lock is unnecessary here.
	// Skipping it removes the dominant serializer of a same-class free storm: N threads
	// dropping objects of the same size class were N-way serialized on one lock
	// (bench_scalar anti-scaled 35->7 Mops/s T1->T8). The atomic fetch_and's PRIOR value
	// gates the count decrement, so even a (buggy) double-free cannot double-subtract —
	// only the caller that actually cleared the set bit decrements. free_index stays a
	// racy-but-safe hint (the two-pass scan in vgc_span_alloc_obj tolerates a stale
	// value). on_central is stably 0 for a mutator-owned span: it is set to 0 at
	// carve/central-pop BEFORE the span reaches the mutator (happens-before via handoff),
	// and drop-return means registered threads never push a span onto a central list.
	// Spans actually ON a central list (on_central != 0: only the unregistered-overflow-
	// thread fallback path) keep the lock, preserving central-list consistency AND the
	// collector's lock-before-suspend fence for them. Validated against the residual-#4
	// churn reproducer + TSan (the exact race the lock was added for).
	mask := u8(1) << (obj_idx & 7)
	byte_ptr := unsafe { &u8(voidptr(usize(span.alloc_bits) + usize(obj_idx >> 3))) }
	if span.on_central == 0 {
		old := C.vgc_atomic_fetch_and_u8(byte_ptr, ~mask)
		if (old & mask) != 0 {
			C.vgc_atomic_sub_u32(&u32(voidptr(&span.alloc_count)), 1)
			unsafe {
				if obj_idx < span.free_index {
					span.free_index = obj_idx
				}
			}
			vgc_acct_free(u64(span.elem_size))
			$if vgc_freering ? {
				vgc_freering_record(span.base + usize(obj_idx) * usize(span.elem_size),
					usize(C.vgc_ra0()), usize(C.vgc_ra1()), usize(C.vgc_ra2()))
			}
		}
		return
	}
	central := unsafe { &vgc_heap.central[span_class] }
	C.vgc_mutex_lock(&central.lock)
	if C.vgc_bitmap_get(span.alloc_bits, obj_idx) != 0 {
		// Atomic clear (AND ~mask) + atomic count: pairs with the lock-free
		// atomic OR in vgc_span_alloc_obj so a free racing a concurrent
		// mcache allocation of a sibling slot in the same byte cannot lose
		// either update. (central.lock still serializes free-vs-free for
		// double-free idempotency and guards the central-list reads.)
		old := C.vgc_atomic_fetch_and_u8(byte_ptr, ~mask)
		if (old & mask) != 0 {
			C.vgc_atomic_sub_u32(&u32(voidptr(&span.alloc_count)), 1)
			unsafe {
				if obj_idx < span.free_index {
					span.free_index = obj_idx
				}
			}
			vgc_acct_free(u64(span.elem_size))
			$if vgc_freering ? {
				vgc_freering_record(span.base + usize(obj_idx) * usize(span.elem_size),
					usize(C.vgc_ra0()), usize(C.vgc_ra1()), usize(C.vgc_ra2()))
			}
		}
	}
	C.vgc_mutex_unlock(&central.lock)
}

// DIAGNOSTIC: report allocation state of an address. Returns a packed status:
// 0 = no span (not a vgc heap ptr); else bit0=alloc_bit_set, bit1=span.in_use,
// and the high bits carry alloc_count (for the residual live-object-sweep probe).
@[markused]
fn vgc_is_allocated(ptr voidptr) u64 {
	if ptr == unsafe { nil } {
		return 0
	}
	span := vgc_find_span(ptr)
	if span == unsafe { nil } {
		return 0
	}
	if span.elem_size == 0 {
		return 2 // span exists but elem_size 0
	}
	obj_idx := u32((usize(ptr) - span.base) / usize(span.elem_size))
	mut st := u64(0)
	if span.in_use {
		st |= 2
	}
	if obj_idx < span.nelems && span.alloc_bits != unsafe { nil } {
		if C.vgc_bitmap_get(span.alloc_bits, obj_idx) != 0 {
			st |= 1
		}
	}
	st |= u64(span.alloc_count) << 8
	return st
}

// ── #57/#58 FREE-PROVENANCE RING (-d vgc_freering) ──────────────────────────
// Attributes a bf1 UAF catch to the event that cleared the victim's alloc bit:
// an EXPLICIT vgc_free (Perceus drop / builtin free / map internals) vs the GC
// sweep. Every successful explicit clear records (ptr, ra0, ra1, ra2) in a
// lock-free global ring; vgc_uaf_check_buf scans the ring on a catch.
//   0xfee0 victim ptr found in ring => EXPLICITLY FREED while live (NOT a GC
//          root-scan bug); 0xfee1/2/3 = return-address chain of the freeing
//          call (symbolicate offline via the 0xba5e anchor); 0xfee5 = byte
//          delta ring-ptr→victim; 0xfee4 = age in frees.
//   0x5e77 not in ring => the clear came from sweep (or pre-ring history);
//          0x5e78 = total explicit frees so far (eviction-risk check).
// Ring writes are racy-by-design (slot overwrite, torn entries tolerable in a
// diagnostic); cost per free is 4 plain stores + 1 atomic increment => far
// below the masking threshold. Compiled out of default builds entirely.
const vgc_freering_size = 262144 // 2^18 entries (~8 MB total side tables)

__global vgc_freering_ptrs = [262144]usize{}
__global vgc_freering_ra0s = [262144]usize{}
__global vgc_freering_ra1s = [262144]usize{}
__global vgc_freering_ra2s = [262144]usize{}
__global vgc_freering_idx = u32(0)
__global vgc_freering_anchor_said = u32(0)

@[inline]
fn vgc_freering_record(ptr usize, ra0 usize, ra1 usize, ra2 usize) {
	i := C.vgc_atomic_add_u32(&vgc_freering_idx, 1) - 1
	slot := int(i & u32(vgc_freering_size - 1))
	vgc_freering_ptrs[slot] = ptr
	vgc_freering_ra0s[slot] = ra0
	vgc_freering_ra1s[slot] = ra1
	vgc_freering_ra2s[slot] = ra2
}

// vgc_freering_lookup: on a bf1 catch, walk the ring newest→oldest for an entry
// whose recorded base ptr is at/just-below the victim address (an explicit free
// records the object base; the victim char-buffer read may sit at base). Emits
// the verdict tags above. Bounded (one pass over ≤2^18 slots) and only runs on
// the rare catch path — cannot mask.
fn vgc_freering_lookup(strptr usize) {
	if vgc_freering_anchor_said == 0 {
		vgc_freering_anchor_said = 1
		C.vgc_say(0xba5e, u64(usize(C.vgc_ra_anchor()))) // text anchor for ASLR slide
	}
	total := C.vgc_atomic_load_u32(&vgc_freering_idx)
	mut n := u32(vgc_freering_size)
	if total < n {
		n = total
	}
	for k in 0 .. int(n) {
		i := int((total - 1 - u32(k)) & u32(vgc_freering_size - 1))
		p := vgc_freering_ptrs[i]
		if p != 0 && strptr >= p && strptr - p < 64 {
			C.vgc_say(0xfee0, u64(strptr))
			C.vgc_say(0xfee1, u64(vgc_freering_ra0s[i]))
			C.vgc_say(0xfee2, u64(vgc_freering_ra1s[i]))
			C.vgc_say(0xfee3, u64(vgc_freering_ra2s[i]))
			C.vgc_say(0xfee4, u64(u32(k)))
			C.vgc_say(0xfee5, u64(strptr - p))
			return
		}
	}
	C.vgc_say(0x5e77, u64(strptr))
	C.vgc_say(0x5e78, u64(total))
}

// DIAGNOSTIC (residual live-object-reclamation probe): watch one heap address
// across GC cycles and record whether the collector treated it as a root, marked
// it, swept it, or decommitted its span. A test sets the watch per wave (e.g.
// vgc_set_watch(c)) and reads vgc_watch_report() at a stall. Gated by
// vgc_watch_addr != 0 so it is a no-op (one compare) when unused.
__global vgc_watch_addr     = usize(0)
__global vgc_watch_in_root  = u32(0) // UNUSED (the per-shade hook perturbed timing; removed)
__global vgc_watch_marked   = u32(0) // vgc_shade() set the mark bit for the watched object
__global vgc_watch_swept    = u32(0) // vgc_sweep_span() cleared the watched object's alloc bit
__global vgc_watch_decommit = u32(0) // vgc_put_free_span() returned the watched object's span
__global vgc_watch_cycles   = u32(0) // GC cycles observed since the watch was set

// ROOT-SCAN-MISS localizers (set ONLY in the bounded root-scan paths
// vgc_mark_roots / vgc_scan_suspended_roots / the spawn-root shade loop — NEVER
// in the per-word vgc_shade mark drain, so they do not perturb the timing-
// sensitive residual). Each records WHICH scanned root (if any) held a pointer to
// the watched object this cycle; combined with vgc_watch_marked they pin whether
// the miss is "no root held it" vs "a root held it but the mark/sweep dropped it".
__global vgc_watch_in_stack = u32(0) // (thread idx+1) whose [stack_lo,stack_hi] held a word == watch_addr
__global vgc_watch_in_reg   = u32(0) // (thread idx+1) whose captured registers held watch_addr
__global vgc_watch_in_spawn = u32(0) // bit0=a spawn-root ptr == watch_addr; bit1=a spawn-root OBJECT held a word == watch_addr
__global vgc_watch_rng_cov  = u32(0) // (thread idx+1) whose [stack_lo,stack_hi] numerically COVERS watch_addr

// vgc_set_watch arms the diagnostic GC watch on the object at `ptr`, resetting the
// per-watch counters (root/marked/swept/decommit/cycles/stack hits) so a single
// object can be tracked across collection cycles. It is a debugging aid for the
// vgc backend and has no effect on normal allocation or collection.
@[markused]
pub fn vgc_set_watch(ptr voidptr) {
	vgc_watch_in_root = 0
	vgc_watch_marked = 0
	vgc_watch_swept = 0
	vgc_watch_decommit = 0
	vgc_watch_cycles = 0
	vgc_watch_in_stack = 0
	vgc_watch_in_reg = 0
	vgc_watch_in_spawn = 0
	vgc_watch_rng_cov = 0
	for i in 0 .. 8 {
		vgc_watch_stage[i] = 0
		vgc_watch_stage_span[i] = 0
	}
	C.vgc_atomic_fence()
	vgc_watch_addr = usize(ptr)
}

// DIAGNOSTIC: scan a root range [lo,hi) for a word whose value == vgc_watch_addr
// (a stack/heap-resident pointer to the watched object) and record the 1-based
// thread index. Also records numeric range coverage. Runs ONLY when a watch is
// set and ONLY over bounded root ranges (the stacks, the spawn-arg objects) — it
// is NOT on the per-word mark-drain path, so it leaves the residual's timing
// intact (the earlier per-shade hook masked the bug; this does not).
fn vgc_watch_scan_range(lo usize, hi usize, idx int) {
	w := vgc_watch_addr
	if w == 0 || lo == 0 || hi <= lo {
		return
	}
	if w >= lo && w < hi {
		vgc_watch_rng_cov = u32(idx + 1)
	}
	start := (lo + sizeof(usize) - 1) & ~(usize(sizeof(usize)) - 1)
	mut addr := start
	for addr + sizeof(usize) <= hi {
		val := unsafe { *(&usize(voidptr(addr))) }
		if val == w {
			vgc_watch_in_stack = u32(idx + 1)
			return
		}
		addr += sizeof(usize)
	}
}

// DIAGNOSTIC: does spawn-arg object p hold a pointer to the watched object
// (i.e. does shading the arg actually reach c via arg->...->c)? Sets bit1 of
// vgc_watch_in_spawn. Bounded to one span elem; gated on a live watch.
fn vgc_watch_scan_obj(p usize) {
	w := vgc_watch_addr
	if w == 0 || p == 0 {
		return
	}
	span := vgc_find_span(voidptr(p))
	if span == unsafe { nil } || !span.in_use || span.elem_size == 0 {
		return
	}
	end := p + usize(span.elem_size)
	mut addr := p & ~(usize(sizeof(usize)) - 1)
	for addr + sizeof(usize) <= end {
		val := unsafe { *(&usize(voidptr(addr))) }
		if val == w {
			vgc_watch_in_spawn |= 2
			return
		}
		addr += sizeof(usize)
	}
}

// Packed report: bit0=in_root bit1=marked bit2=swept bit3=decommit, high bits=cycles.
@[markused]
fn vgc_watch_report() u64 {
	mut r := u64(0)
	if vgc_watch_in_root != 0 {
		r |= 1
	}
	if vgc_watch_marked != 0 {
		r |= 2
	}
	if vgc_watch_swept != 0 {
		r |= 4
	}
	if vgc_watch_decommit != 0 {
		r |= 8
	}
	r |= u64(vgc_watch_cycles) << 8
	return r
}

// Packed root-scan localizer report: byte0=in_stack(thread idx+1),
// byte1=in_reg(thread idx+1), byte2=in_spawn(bit0 direct / bit1 via-arg-object),
// byte3=rng_cov(thread idx+1). All zero ⇒ NO scanned root held a pointer to the
// watched object this cycle = a genuine root-scan miss. Nonzero in_stack/in_reg/
// in_spawn while vgc_watch_marked==0 ⇒ a root held it but the mark/sweep dropped it.
@[markused]
fn vgc_watch_roots_report() u64 {
	mut r := u64(vgc_watch_in_stack & 0xff)
	r |= u64(vgc_watch_in_reg & 0xff) << 8
	r |= u64(vgc_watch_in_spawn & 0xff) << 16
	r |= u64(vgc_watch_rng_cov & 0xff) << 24
	return r
}

// STAGED mark-probe: now that root discovery is proven to FIND c (vgc_watch_roots
// shows c in main's reg + a worker stack + the spawn arg), pin WHERE the mark
// fails. vgc_watch_snapshot(stage) records the watched object's span state at a
// checkpoint in vgc_gc_start; per-stage packed bits: bit0=span found, bit1=in_use,
// bit2=alloc_bit set, bit3=mark_bit set. vgc_watch_stage_span carries span.base
// (identity) so we can see if mark and sweep operate on DIFFERENT spans. 6 calls
// per cycle — off the per-word hot path.
__global vgc_watch_stage      = [8]u64{}
__global vgc_watch_stage_span = [8]u64{}

fn vgc_watch_snapshot(stage int) {
	if vgc_watch_addr == 0 || stage < 0 || stage >= 8 {
		return
	}
	w := vgc_watch_addr
	mut v := u64(0)
	mut sbase := u64(0)
	span := vgc_find_span(voidptr(w))
	if span != unsafe { nil } {
		v |= 1
		sbase = u64(span.base)
		if span.in_use {
			v |= 2
		}
		if span.elem_size != 0 {
			obj_idx := u32((w - span.base) / usize(span.elem_size))
			if obj_idx < span.nelems {
				if span.alloc_bits != unsafe { nil } && C.vgc_bitmap_get(span.alloc_bits, obj_idx) != 0 {
					v |= 4
				}
				if span.mark_bits != unsafe { nil } && C.vgc_bitmap_get(span.mark_bits, obj_idx) != 0 {
					v |= 8
				}
			}
		}
		if span.noscan {
			v |= 32 // bit5: span is noscan (would never be scanned for outgoing ptrs)
		}
	}
	// bit4: does w pass vgc_shade's FAST-REJECT arena-bounds gate? vgc_shade
	// returns immediately (never marks) if this fails — yet find_span (bit0) and
	// sweep use the independent addr_map. A bit0=1,bit4=0 stage = the smoking gun:
	// the object is a real heap object that vgc_shade refuses to mark.
	if w >= vgc_arena_lo && w < vgc_arena_hi {
		v |= 16
	}
	vgc_watch_stage[stage] = v
	vgc_watch_stage_span[stage] = sbase
}

@[markused]
fn vgc_watch_stage_report(stage int) u64 {
	if stage < 0 || stage >= 8 {
		return 0
	}
	return vgc_watch_stage[stage]
}

@[markused]
fn vgc_watch_stage_span_report(stage int) u64 {
	if stage < 0 || stage >= 8 {
		return 0
	}
	return vgc_watch_stage_span[stage]
}

@[markused]
fn vgc_arena_lo_report() u64 {
	return u64(vgc_arena_lo)
}

@[markused]
fn vgc_arena_hi_report() u64 {
	return u64(vgc_arena_hi)
}

// Calloc (zero-initialized allocation)
fn vgc_calloc(n usize) voidptr {
	return vgc_malloc(n) // vgc_malloc already zeroes memory
}

// Typed memdup: allocate with pointer map and copy source data.
// Used by HEAP_vgc() macro for struct allocations with known layout.
@[markused]
fn vgc_memdup_typed(src voidptr, n isize, ptrmap u64, ptr_words u8) voidptr {
	if src == unsafe { nil } || n <= 0 {
		return unsafe { nil }
	}
	mem := vgc_malloc_typed_opts(usize(n), ptrmap, ptr_words, false)
	if mem != unsafe { nil } {
		$if vgc_concurrent ? {
			vgc_wb_store(mem) // concurrent-mark barrier: dup'd bytes may hold pointers
		}
		unsafe { C.memcpy(mem, src, n) }
	}
	return mem
}

// Memdup variants that skip zero-fill when the destination will be overwritten.
@[markused]
fn vgc_memdup(src voidptr, n isize) voidptr {
	if src == unsafe { nil } || n <= 0 {
		return unsafe { nil }
	}
	mem := vgc_malloc_typed_opts(usize(n), 0, 0, false)
	if mem != unsafe { nil } {
		$if vgc_concurrent ? {
			vgc_wb_store(mem) // concurrent-mark barrier: dup'd bytes may hold pointers
		}
		unsafe { C.memcpy(mem, src, n) }
	}
	return mem
}

@[markused]
fn vgc_memdup_noscan(src voidptr, n isize) voidptr {
	if src == unsafe { nil } || n <= 0 {
		return unsafe { nil }
	}
	mem := vgc_malloc_noscan_opts(usize(n), false)
	if mem != unsafe { nil } {
		unsafe { C.memcpy(mem, src, n) }
	}
	return mem
}

// ============================================================
// Span lookup (find which span owns an address) - O(1) via address map
// ============================================================

fn vgc_find_span(ptr voidptr) &VGC_Span {
	addr := usize(ptr)
	// The addr_map is a COARSE 1GB-granularity hint (VGC_ADDR_SHIFT=30) but arenas
	// are only 64MB (vgc_arena_size), so up to 16 arenas share one chunk and each
	// new arena's vgc_addr_map_register OVERWRITES the chunk's single entry. The
	// hint therefore resolves only the NEWEST arena in a shared chunk; an address
	// in an older arena of that chunk would otherwise be reported as "no span".
	// That asymmetry is fatal: vgc_shade(addr) bails on a nil span and never marks
	// the object, while vgc_do_sweep walks allspans directly and frees it -> a
	// live, reachable object is reclaimed (the residual P3 bug). So: use the hint,
	// but if it does not actually contain addr, fall back to a linear scan over all
	// arenas (narenas <= vgc_max_arenas = 64) so find_span is as complete as the
	// allspans sweep. (Collection is rare behind the Perceus front line; the scan
	// only runs on a hint miss.)
	// ACQUIRE-load narenas (paired with the RELEASE store in vgc_span_alloc): if we
	// observe a given count, we also observe the fully-initialized arenas[] entries
	// + page maps it gates. A plain read here raced the locked writer (TSan).
	nar := int(C.vgc_atomic_load_u32(&u32(voidptr(&vgc_heap.narenas))))
	mut arena_idx := C.vgc_addr_to_arena(addr)
	if arena_idx < 0 || arena_idx >= nar
		|| addr < vgc_heap.arenas[arena_idx].base
		|| addr >= vgc_heap.arenas[arena_idx].base + vgc_heap.arenas[arena_idx].size {
		arena_idx = -1
		for i in 0 .. nar {
			a := unsafe { &vgc_heap.arenas[i] }
			if addr >= a.base && addr < a.base + a.size {
				arena_idx = i
				break
			}
		}
		if arena_idx < 0 {
			return unsafe { nil }
		}
	}
	a := unsafe { &vgc_heap.arenas[arena_idx] }
	page_idx := (addr - a.base) / vgc_page_size
	if page_idx < vgc_pages_per_arena {
		// ACQUIRE-load the page_span slot (paired with vgc_span_alloc's RELEASE
		// store). This reader is lock-free (the collector calls it during STW and
		// the mutator calls it from vgc_free/vgc_realloc), so it cannot take
		// vgc_heap.lock; the per-slot atomic gives the happens-before that the
		// locked writer's plain store lacked for existing-arena span carves.
		return unsafe { &VGC_Span(voidptr(C.vgc_atomic_load_u64(&u64(voidptr(&a.page_span[page_idx]))))) }
	}
	return unsafe { nil }
}

// Get the allocation size of an object
fn vgc_get_obj_size(ptr voidptr) usize {
	span := vgc_find_span(ptr)
	if span == unsafe { nil } {
		return 0
	}
	return usize(span.elem_size)
}

// Check if an address is within the GC heap - O(1) with fast bounds reject
fn vgc_is_heap_ptr(addr usize) bool {
	// Fast reject: most words on the stack are NOT heap pointers
	if addr < vgc_arena_lo || addr >= vgc_arena_hi {
		return false
	}
	arena_idx := C.vgc_addr_to_arena(addr)
	// ACQUIRE-load narenas (paired with vgc_span_alloc's RELEASE store).
	if arena_idx < 0 || arena_idx >= int(C.vgc_atomic_load_u32(&u32(voidptr(&vgc_heap.narenas)))) {
		return false
	}
	a := unsafe { &vgc_heap.arenas[arena_idx] }
	return addr >= a.base && addr < a.base + a.used
}

// Safepoint: called when GC needs threads to stop. Spills callee-saved
// registers (vgc_park_spill) before recording the stack range, so roots that
// live only in registers are scanned. Marks stopped, then spins until the
// collector finishes the (full) stop-the-world mark+sweep.
fn vgc_safepoint() {
	cache_idx := C.vgc_get_cache_idx()
	if cache_idx < 0 {
		return
	}
	unsafe {
		C.vgc_park_spill(&vgc_heap.gc_stop_flag, &vgc_heap.gc_stopped_count,
			&vgc_heap.caches[cache_idx].stopped, &vgc_heap.caches[cache_idx].stack_lo,
			&vgc_heap.caches[cache_idx].stack_hi, vgc_heap.caches[cache_idx].stack_base)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// #63/#145 PASSIVE CAPTURE INSTRUMENT — masking-proof sweep-while-live ORACLE.
// Ported (verbatim semantics) from diagnostic branch issue63-passive-instrument
// (commit f3e962e6fb) onto the SHIPPING cooperative-safepoint collector so the
// concurrency-soundness gate exercises the real shipping binary (the prior gate
// built these defines as silent no-ops — the fork lacked the instrument, so the
// 0xbf1 grep could never match). Includes ONLY: (1) UAF detector at the crash-path
// read, (2) swept-log written by the sweep free-path (vgc_slog_record), (3) GOLD
// correlation (read-after-free vs swept-log). EXCLUDES arming/quarantine/holder-
// find/forced-collects (those masked the crash). Function bodies always compile;
// only CALLED from `$if vgc_passive ?` sites (map.v/string.v/sweep), so the default
// build is unaffected. Tags: 0xbf1=freed buf ptr, 0xbf2=len, 0xbf3=size-class;
// 0xc0de=GOLD victim, 0xc0d1=freed-at-gen; 0xda1-3/0xdb0/0xdc0=absurd-len report.
// ─────────────────────────────────────────────────────────────────────────────

const vgc_slog_n = 65536
__global vgc_slog_addr = [65536]usize{} // freed small-buffer addrs (ring)
__global vgc_slog_gen = [65536]u32{} // gc gen when freed
__global vgc_slog_sc = [65536]u32{} // size class
__global vgc_slog_head = u32(0)
__global vgc_slog_total = u64(0) // total small frees recorded (stat)
__global vgc_uaf_count = u32(0)
__global vgc_gold_total = u64(0) // total GOLD correlations (swept -> read-after-free)

// vgc_slog_record: called from the sweep free-path (STW) for each freed small
// noscan buffer. Lock-free ring push (collector is the only writer during STW).
fn vgc_slog_record(addr usize, sc u32) {
	vgc_slog_total++
	h := vgc_slog_head % u32(vgc_slog_n)
	vgc_slog_addr[h] = addr
	vgc_slog_gen[h] = u32(vgc_heap.gc_cycle)
	vgc_slog_sc[h] = sc
	vgc_slog_head = h + 1
}

// vgc_slog_find: was `addr` recorded as swept-freed? Returns gen+1 if so, else 0.
fn vgc_slog_find(addr usize) u64 {
	for i in 0 .. vgc_slog_n {
		if vgc_slog_addr[i] == addr {
			return u64(vgc_slog_gen[i]) + 1
		}
	}
	return 0
}

// vgc_uaf_classify: report size class + alloc/mark/noscan state of the GC object
// at `addr` (or a sentinel if non-arena / not a live span object).
fn vgc_uaf_classify(tag u64, addr usize) {
	if addr < vgc_arena_lo || addr >= vgc_arena_hi {
		C.vgc_say(tag, u64(0xffffffffffffffff)) // not in GC arena (C/anon/stack)
		return
	}
	span := vgc_find_span(voidptr(addr))
	if span == unsafe { nil } || !span.in_use || span.elem_size == 0 {
		C.vgc_say(tag, u64(0xdeadbeef))
		return
	}
	idx := u32((addr - span.base) / usize(span.elem_size))
	mut a := u32(9)
	mut m := u32(9)
	if span.alloc_bits != unsafe { nil } && idx < span.nelems {
		a = u32(C.vgc_bitmap_get(span.alloc_bits, idx))
	}
	if span.mark_bits != unsafe { nil } && idx < span.nelems {
		m = u32(C.vgc_bitmap_get(span.mark_bits, idx))
	}
	C.vgc_say(tag, u64(span.elem_size))
	C.vgc_say(tag + 1, (u64(a) << 4) | u64(m))
	C.vgc_say(tag + 2, if span.noscan { u64(1) } else { u64(0) })
}

// vgc_uaf_report: an absurd .len was read from a key struct (struct freed + span
// reused with payload bytes). Reports the read + classifies the holder + buffer.
fn vgc_uaf_report(loc usize, slen int, strptr usize) {
	vgc_uaf_count++
	if vgc_uaf_count > 60 {
		return
	}
	C.vgc_say(0xda1, u64(loc))
	C.vgc_say(0xda2, u64(u32(slen)))
	C.vgc_say(0xda3, u64(strptr))
	vgc_uaf_classify(0xdb0, loc)
	vgc_uaf_classify(0xdc0, strptr)
}

// vgc_uaf_check_buf: inspects ONLY span metadata for the char buffer at `strptr`
// (never the possibly-unmapped data page — crash-safe), reporting whether it has
// been freed (alloc bit clear) or its span recycled. Returns true on a freed
// buffer = a direct buffer-UAF. A swept-log hit ⇒ GOLD (sweep-freed → read).
fn vgc_uaf_check_buf(strptr usize, slen int) bool {
	if strptr < vgc_arena_lo || strptr >= vgc_arena_hi {
		return false // literal / malloc / non-GC memory — not a vgc free
	}
	span := vgc_find_span(voidptr(strptr))
	if span == unsafe { nil } || !span.in_use || span.elem_size == 0 {
		vgc_uaf_count++
		if vgc_uaf_count <= 200 {
			C.vgc_say(0xbf1, u64(strptr))
			C.vgc_say(0xbf2, u64(u32(slen)))
			C.vgc_say(0xbf3, u64(0xdec0)) // span recycled/decommitted
			g := vgc_slog_find(strptr)
			if g != 0 { // GOLD: sweep-freed at gen g-1 → read-after-free
				vgc_gold_total++
				C.vgc_say(0xc0de, u64(strptr))
				C.vgc_say(0xc0d1, g - 1)
			}
			$if vgc_freering ? {
				vgc_freering_lookup(strptr)
			}
		}
		$if cx_watch_keytext ? {
			vgc_watch_addr = strptr // #145 deep-fix A: re-arm on the PROVEN victim slot
		}
		return true
	}
	idx := u32((strptr - span.base) / usize(span.elem_size))
	mut a := u32(9)
	if span.alloc_bits != unsafe { nil } && idx < span.nelems {
		a = u32(C.vgc_bitmap_get(span.alloc_bits, idx))
	}
	if a == 0 {
		vgc_uaf_count++
		if vgc_uaf_count <= 200 {
			C.vgc_say(0xbf1, u64(strptr))
			C.vgc_say(0xbf2, u64(u32(slen)))
			C.vgc_say(0xbf3, u64(span.elem_size)) // size class of the freed buffer
			g := vgc_slog_find(strptr)
			if g != 0 { // GOLD correlation
				vgc_gold_total++
				C.vgc_say(0xc0de, u64(strptr))
				C.vgc_say(0xc0d1, g - 1)
			}
			$if vgc_freering ? {
				vgc_freering_lookup(strptr)
			}
		}
		$if cx_watch_keytext ? {
			vgc_watch_addr = strptr // #145 deep-fix A: re-arm on the PROVEN victim slot
		}
		return true
	}
	return false
}
