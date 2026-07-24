@[has_globals]
module builtin

// v_memory_panic will be true, *only* when a call to malloc/realloc/vcalloc etc could not succeed.
// In that situation, functions that are registered with at_exit(), should be able to limit their
// activity accordingly, by checking this flag.
// The V compiler itself for example registers a function with at_exit(), for showing timers.
// Without a way to distinguish, that we are in a memory panic, that would just display a second panic,
// which would be less clear to the user.
__global v_memory_panic = false

@[noreturn]
fn _memory_panic(fname string, size isize) {
	v_memory_panic = true
	// Note: do not use string interpolation here at all, since string interpolation itself allocates
	eprint(fname)
	eprint('(')
	$if freestanding || vinix || v2_native_windows_pe_minimal ? {
		eprint('size') // TODO: use something more informative here
	} $else {
		C.fprintf(C.stderr, c'%p', voidptr(size))
	}
	if size < 0 {
		eprint(' < 0')
	}
	eprintln(')')
	panic('memory allocation failure')
}

__global total_m = i64(0)

// Opt-in heap allocation hooks, enabled with `-d track_heap`. When the flag is
// set, every heap allocation calls `vheap_alloc(ptr, size)` and every free calls
// `vheap_free(ptr)`; link an external profiler / leak tracker that implements
// them to observe live allocations at runtime. The `@[if track_heap ?]` attribute
// compiles the hooks to no-ops (zero cost) when the flag is off.
//
// track_heap models *manual* memory management (`-gc none`): the free hook only
// fires on the manual-free path, so under a GC the collector reclaims blocks with
// no matching hook and they would be reported as permanently live. Reject that
// combination at C compile time rather than emit misleading stats. The guard is
// emitted as C preprocessor code so `-cross` can still preserve conditional C.
#insert "@VEXEROOT/vlib/builtin/track_heap_checks.h"

fn C.vheap_alloc(p voidptr, n u64)
fn C.vheap_free(p voidptr)

@[if track_heap ?]
fn _ht_alloc(p &u8, n isize) {
	C.vheap_alloc(p, u64(n))
}

@[if track_heap ?]
fn _ht_free(p voidptr) {
	C.vheap_free(p)
}

// malloc dynamically allocates a `n` bytes block of memory on the heap.
// malloc returns a `byteptr` pointing to the memory address of the allocated space.
// unlike the `calloc` family of functions - malloc will not zero the memory block.
@[unsafe]
pub fn malloc(n isize) &u8 {
	$if trace_malloc ? {
		total_m += n
		C.fprintf(C.stderr, c'_v_malloc %6d total %10d\n', n, total_m)
		// print_backtrace()
	}
	if n < 0 {
		_memory_panic(@FN, n)
	} else if n == 0 {
		return &u8(unsafe { nil })
	}
	mut res := &u8(unsafe { nil })
	$if prealloc {
		return unsafe { prealloc_malloc(n) }
	} $else $if vgc ? {
		unsafe {
			res = &u8(vgc_malloc(usize(n)))
		}
	} $else $if gcboehm ? {
		unsafe {
			res = C.GC_MALLOC(n)
		}
	} $else $if freestanding {
		// todo: is this safe to call malloc there? We export __malloc as malloc and it uses dlmalloc behind the scenes
		// so theoretically it is safe
		res = unsafe { __malloc(usize(n)) }
	} $else {
		$if windows {
			// Warning! On windows, we always use _aligned_malloc to allocate memory.
			// This ensures that we can later free the memory with _aligned_free
			// without needing to track whether the memory was originally allocated
			// by malloc or _aligned_malloc.
			res = unsafe { C._aligned_malloc(n, 1) }
		} $else {
			res = unsafe { C.malloc(n) }
		}
	}
	if res == 0 {
		_memory_panic(@FN, n)
	}
	$if debug_malloc ? {
		// Fill in the memory with something != 0 i.e. `M`, so it is easier to spot
		// when the calling code wrongly relies on it being zeroed.
		unsafe { C.memset(res, 0x4D, n) }
	}
	_ht_alloc(res, n)
	return res
}

@[unsafe]
pub fn malloc_noscan(n isize) &u8 {
	$if trace_malloc ? {
		total_m += n
		C.fprintf(C.stderr, c'malloc_noscan %6d total %10d\n', n, total_m)
		// print_backtrace()
	}
	if n < 0 {
		_memory_panic(@FN, n)
	}
	mut res := &u8(unsafe { nil })
	$if prealloc {
		return unsafe { prealloc_malloc(n) }
	} $else $if vgc ? {
		unsafe {
			res = &u8(vgc_malloc_noscan(usize(n)))
		}
	} $else $if gcboehm ? {
		$if gcboehm_opt ? {
			unsafe {
				res = C.GC_MALLOC_ATOMIC(n)
			}
		} $else {
			unsafe {
				res = C.GC_MALLOC(n)
			}
		}
	} $else $if freestanding {
		res = unsafe { __malloc(usize(n)) }
	} $else {
		$if windows {
			// Warning! On windows, we always use _aligned_malloc to allocate memory.
			// This ensures that we can later free the memory with _aligned_free
			// without needing to track whether the memory was originally allocated
			// by malloc or _aligned_malloc.
			res = unsafe { C._aligned_malloc(n, 1) }
		} $else {
			res = unsafe { C.malloc(n) }
		}
	}
	if res == 0 {
		_memory_panic(@FN, n)
	}
	$if debug_malloc ? {
		// Fill in the memory with something != 0 i.e. `M`, so it is easier to spot
		// when the calling code wrongly relies on it being zeroed.
		unsafe { C.memset(res, 0x4D, n) }
	}
	_ht_alloc(res, n)
	return res
}

@[unsafe]
fn malloc_uninit(n isize) &u8 {
	if n < 0 {
		_memory_panic(@FN, n)
	} else if n == 0 {
		return &u8(unsafe { nil })
	}
	$if vgc ? {
		return unsafe { &u8(vgc_malloc_typed_opts(usize(n), 0, 0, false)) }
	}
	return malloc(n)
}

@[unsafe]
fn malloc_noscan_uninit(n isize) &u8 {
	if n < 0 {
		_memory_panic(@FN, n)
	} else if n == 0 {
		return &u8(unsafe { nil })
	}
	$if vgc ? {
		return unsafe { &u8(vgc_malloc_noscan_opts(usize(n), false)) }
	}
	return malloc_noscan(n)
}

@[inline]
fn __at_least_one(how_many u64) u64 {
	// handle the case for allocating memory for empty structs, which have sizeof(EmptyStruct) == 0
	// in this case, just allocate a single byte, avoiding the panic for malloc(0)
	if how_many == 0 {
		return 1
	}
	return how_many
}

// malloc_uncollectable dynamically allocates a `n` bytes block of memory
// on the heap, which will NOT be garbage-collected (but its contents will).
@[unsafe]
pub fn malloc_uncollectable(n isize) &u8 {
	$if trace_malloc ? {
		total_m += n
		C.fprintf(C.stderr, c'malloc_uncollectable %6d total %10d\n', n, total_m)
		// print_backtrace()
	}
	if n < 0 {
		_memory_panic(@FN, n)
	}

	mut res := &u8(unsafe { nil })
	$if prealloc {
		return unsafe { prealloc_malloc(n) }
	} $else $if vgc ? {
		unsafe {
			res = &u8(vgc_malloc(usize(n)))
			// Honor BOTH halves of the uncollectable contract (Boehm's
			// GC_MALLOC_UNCOLLECTABLE): the block is never collected AND acts
			// as a ROOT whose contents are scanned. A plain vgc_malloc here is
			// unsound: the flagship caller is closure_create's captured-context
			// struct, whose ONLY reference lives in the closure's mmap'd
			// metadata page — memory the collector never scans — so the first
			// GC cycle swept every live closure context (and everything
			// reachable only through it, e.g. the interface box a `fn [b]`
			// capture holds), and the next closure invocation read freed
			// memory. Pinning registers the block in the collector's explicit
			// root set: shaded every cycle, so it and its transitive referents
			// survive for the process lifetime — exactly the Boehm semantics
			// (uncollectable blocks are immortal unless explicitly freed).
			vgc_pin(res)
		}
	} $else $if gcboehm ? {
		unsafe {
			res = C.GC_MALLOC_UNCOLLECTABLE(n)
		}
	} $else $if freestanding {
		res = unsafe { __malloc(usize(n)) }
	} $else {
		$if windows {
			// Warning! On windows, we always use _aligned_malloc to allocate memory.
			// This ensures that we can later free the memory with _aligned_free
			// without needing to track whether the memory was originally allocated
			// by malloc or _aligned_malloc.
			res = unsafe { C._aligned_malloc(n, 1) }
		} $else {
			res = unsafe { C.malloc(n) }
		}
	}
	if res == 0 {
		_memory_panic(@FN, n)
	}
	$if debug_malloc ? {
		// Fill in the memory with something != 0 i.e. `M`, so it is easier to spot
		// when the calling code wrongly relies on it being zeroed.
		unsafe { C.memset(res, 0x4D, n) }
	}
	_ht_alloc(res, n)
	return res
}

// v_realloc resizes the memory block `b` with `n` bytes.
// The `b byteptr` must be a pointer to an existing memory block
// previously allocated with `malloc` or `vcalloc`.
// Please, see also realloc_data, and use it instead if possible.
@[unsafe]
pub fn v_realloc(b &u8, n isize) &u8 {
	$if trace_realloc ? {
		C.fprintf(C.stderr, c'v_realloc %6d\n', n)
	}
	mut new_ptr := &u8(unsafe { nil })
	$if prealloc {
		unsafe {
			new_ptr = malloc(n)
			C.memcpy(new_ptr, b, n)
		}
		return new_ptr
	} $else $if vgc ? {
		new_ptr = unsafe { &u8(vgc_realloc(b, usize(n))) }
	} $else $if gcboehm ? {
		new_ptr = unsafe { C.GC_REALLOC(b, n) }
	} $else {
		$if windows {
			// Warning! On windows, we always use _aligned_realloc to reallocate memory.
			// This ensures that we can later free the memory with _aligned_free
			// without needing to track whether the memory was originally allocated
			// by malloc or _aligned_malloc/_aligned_realloc.
			new_ptr = unsafe { C._aligned_realloc(b, n, 1) }
		} $else {
			new_ptr = unsafe { C.realloc(b, n) }
		}
	}
	if new_ptr == 0 {
		_memory_panic(@FN, n)
	}
	// realloc(nil, …) means "allocate", not "free then allocate" (the stbi
	// STBI_REALLOC path forwards null `b` here), so only report a free when there
	// was a real prior block — mirrors the nil guard in free().
	if b != unsafe { nil } {
		_ht_free(b)
	}
	_ht_alloc(new_ptr, n)
	return new_ptr
}

// realloc_data resizes the memory block pointed by `old_data` to `new_size`
// bytes. `old_data` must be a pointer to an existing memory block, previously
// allocated with `malloc` or `vcalloc`, of size `old_data`.
// realloc_data returns a pointer to the new location of the block.
// Note: if you know the old data size, it is preferable to call `realloc_data`,
// instead of `v_realloc`, at least during development, because `realloc_data`
// can make debugging easier, when you compile your program with
// `-d debug_realloc`.
@[unsafe]
pub fn realloc_data(old_data &u8, old_size int, new_size int) &u8 {
	$if trace_realloc ? {
		C.fprintf(C.stderr, c'realloc_data old_size: %6d new_size: %6d\n', old_size, new_size)
	}
	$if prealloc {
		return unsafe { prealloc_realloc(old_data, old_size, new_size) }
	}
	$if debug_realloc ? {
		// Note: this is slower, but helps debugging memory problems.
		// The main idea is to always force reallocating:
		// 1) allocate a new memory block
		// 2) copy the old to the new
		// 3) fill the old with 0x57 (`W`)
		// 4) free the old block
		// => if there is still a pointer to the old block somewhere
		//    it will point to memory that is now filled with 0x57.
		unsafe {
			new_ptr := malloc(new_size)
			min_size := if old_size < new_size { old_size } else { new_size }
			C.memcpy(new_ptr, old_data, min_size)
			C.memset(old_data, 0x57, old_size)
			free(old_data)
			return new_ptr
		}
	}
	mut nptr := &u8(unsafe { nil })
	$if vgc ? {
		nptr = unsafe { &u8(vgc_realloc(old_data, usize(new_size))) }
	} $else $if gcboehm ? {
		nptr = unsafe { C.GC_REALLOC(old_data, new_size) }
	} $else {
		$if windows {
			// Warning! On windows, we always use _aligned_realloc to reallocate memory.
			// This ensures that we can later free the memory with _aligned_free
			// without needing to track whether the memory was originally allocated
			// by malloc or _aligned_malloc/_aligned_realloc.
			nptr = unsafe { C._aligned_realloc(old_data, new_size, 1) }
		} $else {
			nptr = unsafe { C.realloc(old_data, new_size) }
		}
	}
	if nptr == 0 {
		_memory_panic(@FN, isize(new_size))
	}
	// realloc(nil, …) means "allocate"; don't report a free with no prior block.
	if old_data != unsafe { nil } {
		_ht_free(old_data)
	}
	_ht_alloc(nptr, isize(new_size))
	return nptr
}

// vcalloc dynamically allocates a zeroed `n` bytes block of memory on the heap.
// vcalloc returns a `byteptr` pointing to the memory address of the allocated space.
// vcalloc checks for negative values given in `n`.
pub fn vcalloc(n isize) &u8 {
	$if trace_vcalloc ? {
		total_m += n
		C.fprintf(C.stderr, c'vcalloc %6d total %10d\n', n, total_m)
	}
	if n < 0 {
		_memory_panic(@FN, n)
	} else if n == 0 {
		return &u8(unsafe { nil })
	}
	$if prealloc {
		return unsafe { prealloc_calloc(n) }
	} $else $if vgc ? {
		return unsafe { &u8(vgc_calloc(usize(n))) }
	} $else $if gcboehm ? {
		return unsafe { &u8(C.GC_MALLOC(n)) }
	} $else {
		$if windows {
			// Warning! On windows, we always use _aligned_malloc to allocate memory.
			// This ensures that we can later free the memory with _aligned_free
			// without needing to track whether the memory was originally allocated
			// by malloc or _aligned_malloc/_aligned_realloc/_aligned_recalloc.
			ptr := unsafe { C._aligned_malloc(n, 1) }
			if ptr != &u8(unsafe { nil }) {
				unsafe { C.memset(ptr, 0, n) }
			}
			_ht_alloc(ptr, n)
			return ptr
		} $else {
			r := unsafe { C.calloc(1, n) }
			_ht_alloc(r, n)
			return r
		}
	}
	return &u8(unsafe { nil }) // not reached, TODO: remove when V's checker is improved
}

// special versions of the above that allocate memory which is not scanned
// for pointers (but is collected) when the Boehm garbage collection is used
pub fn vcalloc_noscan(n isize) &u8 {
	$if trace_vcalloc ? {
		total_m += n
		C.fprintf(C.stderr, c'vcalloc_noscan %6d total %10d\n', n, total_m)
	}
	$if prealloc {
		return unsafe { prealloc_calloc(n) }
	} $else $if vgc ? {
		if n < 0 {
			_memory_panic(@FN, n)
		}
		return unsafe { &u8(vgc_calloc(usize(n))) }
	} $else $if gcboehm ? {
		if n < 0 {
			_memory_panic(@FN, n)
		}
		$if gcboehm_opt ? {
			res := unsafe { C.GC_MALLOC_ATOMIC(n) }
			unsafe { C.memset(res, 0, n) }
			return &u8(res)
		} $else {
			res := unsafe { C.GC_MALLOC(n) }
			return &u8(res)
		}
	} $else {
		return unsafe { vcalloc(n) }
	}
	return &u8(unsafe { nil }) // not reached, TODO: remove when V's checker is improved
}

// free allows for manually freeing memory allocated at the address `ptr`.
@[unsafe]
pub fn free(ptr voidptr) {
	$if trace_free ? {
		C.fprintf(C.stderr, c'free ptr: %p\n', ptr)
	}
	$if builtin_free_nop ? {
		return
	}
	if ptr == unsafe { 0 } {
		$if trace_free_nulls ? {
			C.fprintf(C.stderr, c'free null ptr\n', ptr)
		}
		$if trace_free_nulls_break ? {
			break_if_debugger_attached()
		}
		return
	}
	// `none__` is a process-wide singleton IError used by option/results to
	// represent "no error object". Self-hosted builds can still route that
	// sentinel through explicit cleanup paths under `-gc none`, so ignore it.
	none_err := &C.IError(&none__)
	if ptr == none_err._object {
		return
	}
	$if prealloc {
		return
	} $else $if vgc ? {
		// VGC: explicit free is optional (GC will collect unreachable objects).
		// But hint the allocator for faster reuse.
		vgc_free(ptr)
	} $else $if gcboehm ? {
		// It is generally better to leave it to Boehm's gc to free things.
		// Calling C.GC_FREE(ptr) was tried initially, but does not work
		// well with programs that do manual management themselves.
		//
		// The exception is doing leak detection for manual memory management:
		$if gcboehm_leak ? {
			unsafe { C.GC_FREE(ptr) }
		}
	} $else {
		// Manual memory management: this is the only path that actually returns
		// the block to the C allocator, and it mirrors where _ht_alloc fires, so
		// report the free here (after the nil / none__ / nop / GC guards above).
		_ht_free(ptr)
		$if windows {
			// Warning! On windows, we always use _aligned_free to free memory.
			unsafe { C._aligned_free(ptr) }
		} $else {
			C.free(ptr)
		}
	}
}

// memdup dynamically allocates a `sz` bytes block of memory on the heap
// memdup then copies the contents of `src` into the allocated space and
// returns a pointer to the newly allocated space.
@[unsafe]
pub fn memdup(src voidptr, sz isize) voidptr {
	$if trace_memdup ? {
		C.fprintf(C.stderr, c'memdup size: %10d\n', sz)
	}
	if sz == 0 {
		return vcalloc(1)
	}
	$if vgc ? {
		return vgc_memdup(src, sz)
	}
	unsafe {
		mem := malloc(sz)
		return C.memcpy(mem, src, sz)
	}
}

@[unsafe]
pub fn memdup_noscan(src voidptr, sz isize) voidptr {
	$if trace_memdup ? {
		C.fprintf(C.stderr, c'memdup_noscan size: %10d\n', sz)
	}
	if sz == 0 {
		return vcalloc_noscan(1)
	}
	$if vgc ? {
		return vgc_memdup_noscan(src, sz)
	}
	unsafe {
		mem := malloc_noscan(sz)
		return C.memcpy(mem, src, sz)
	}
}

// memdup_uncollectable dynamically allocates a `sz` bytes block of memory
// on the heap, which will NOT be garbage-collected (but its contents will).
// memdup_uncollectable then copies the contents of `src` into the allocated
// space and returns a pointer to the newly allocated space.
@[unsafe]
pub fn memdup_uncollectable(src voidptr, sz isize) voidptr {
	$if trace_memdup ? {
		C.fprintf(C.stderr, c'memdup_uncollectable size: %10d\n', sz)
	}
	if sz == 0 {
		return vcalloc(1)
	}
	unsafe {
		mem := malloc_uncollectable(sz)
		return C.memcpy(mem, src, sz)
	}
}

// free_uncollectable releases a block obtained from malloc_uncollectable /
// memdup_uncollectable — the ONLY correct way to free one. Under vgc the block
// is registered as an explicit GC root (see malloc_uncollectable), so a plain
// free() would leave a stale pin behind: harmless while the slot stays free,
// but once the allocator reuses it the pin silently immortalizes an unrelated
// object. Unpin first, then free. Under the other allocators this is plain
// free() (Boehm's GC_FREE handles uncollectable blocks natively).
@[unsafe]
pub fn free_uncollectable(ptr voidptr) {
	if ptr == unsafe { nil } {
		return
	}
	$if vgc ? {
		vgc_unpin(ptr)
	}
	unsafe { free(ptr) }
}

// memdup_align dynamically allocates a memory block of `sz` bytes on the heap,
// copies the contents from `src` into the allocated space, and returns a pointer
// to the newly allocated memory. The returned pointer is aligned to the specified `align` boundary.
//   - `align` must be a power of two and at least 1
//   - `sz` must be non-negative
//   - The memory regions should not overlap
@[unsafe]
pub fn memdup_align(src voidptr, sz isize, align isize) voidptr {
	$if trace_memdup ? {
		C.fprintf(C.stderr, c'memdup_align size: %10d align: %10d\n', sz, align)
	}
	if sz == 0 {
		return vcalloc(1)
	}
	n := sz
	$if trace_malloc ? {
		total_m += n
		C.fprintf(C.stderr, c'_v_memdup_align %6d total %10d\n', n, total_m)
		// print_backtrace()
	}
	if n < 0 {
		_memory_panic(@FN, n)
	}
	mut res := &u8(unsafe { nil })
	$if prealloc {
		res = prealloc_malloc_align(n, align)
	} $else $if gcboehm ? {
		unsafe {
			res = C.GC_memalign(align, n)
		}
	} $else $if freestanding {
		// todo: is this safe to call malloc there? We export __malloc as malloc and it uses dlmalloc behind the scenes
		// so theoretically it is safe
		panic('memdup_align is not implemented with -freestanding')
		res = unsafe { __malloc(usize(n)) }
	} $else {
		$if windows {
			// Warning! On windows, we always use _aligned_malloc to allocate memory.
			// This ensures that we can later free the memory with _aligned_free
			// without needing to track whether the memory was originally allocated
			// by malloc or _aligned_malloc.
			res = unsafe { C._aligned_malloc(n, align) }
		} $else {
			res = unsafe { C.aligned_alloc(align, n) }
		}
	}
	if res == 0 {
		_memory_panic(@FN, n)
	}
	$if debug_malloc ? {
		// Fill in the memory with something != 0 i.e. `M`, so it is easier to spot
		// when the calling code wrongly relies on it being zeroed.
		unsafe { C.memset(res, 0x4D, n) }
	}
	// memdup_align allocates directly via aligned_alloc / _aligned_malloc, so
	// report it like malloc does; otherwise the later free() of an aligned heap
	// literal (HEAP_align) would emit vheap_free for an untracked pointer.
	_ht_alloc(res, n)
	return C.memcpy(res, src, sz)
}

// GCHeapUsage contains stats about the current heap usage of your program.
pub struct GCHeapUsage {
pub:
	heap_size      usize
	free_bytes     usize
	total_bytes    usize
	unmapped_bytes usize
	bytes_since_gc usize
}

// gc_heap_usage returns the info about heap usage.
pub fn gc_heap_usage() GCHeapUsage {
	$if vgc ? {
		heap_size, free_bytes, total_bytes, unmapped, bytes_since := vgc_heap_usage()
		return GCHeapUsage{
			heap_size:      heap_size
			free_bytes:     free_bytes
			total_bytes:    total_bytes
			unmapped_bytes: unmapped
			bytes_since_gc: bytes_since
		}
	} $else $if gcboehm ? {
		mut res := GCHeapUsage{}
		C.GC_get_heap_usage_safe(&res.heap_size, &res.free_bytes, &res.unmapped_bytes,
			&res.bytes_since_gc, &res.total_bytes)
		return res
	} $else {
		return GCHeapUsage{}
	}
}

// gc_memory_use returns the total memory use in bytes by all allocated blocks.
pub fn gc_memory_use() usize {
	$if vgc ? {
		return vgc_memory_use()
	} $else $if gcboehm ? {
		return C.GC_get_memory_use()
	} $else {
		return 0
	}
}

// GcChurnMetric selects what gc_collect_if_churned measures growth against.
pub enum GcChurnMetric {
	// committed — sum of arena bytes carved (vgc: Σ arenas.used; boehm:
	// GC_get_memory_use). Monotonic: grows on new carves, never shrinks on sweep
	// (freed spans stay committed by design). MEASURED on #131: gating on its
	// delta does NOT bound RSS — new carves outpace the gate and committed is
	// never returned, so RSS keeps climbing (82→326 MB at N=4 where .allocated
	// holds flat). Cheaper to read than .allocated, but only suitable where the
	// working set is genuinely stable. Prefer .allocated for server workloads.
	committed
	// allocated — cumulative bytes ever allocated (vgc: total_alloc accounting,
	// flushed every ~1 MB per cache). Tracks allocation CHURN even when freed
	// spans are reused, so it keeps firing on a steady-state transient-heavy
	// workload — collecting before new spans must carve, which holds RSS at the
	// working-set floor (MEASURED #131: flat ~49 MB where committed climbs).
	// vgc-only; falls back to committed elsewhere.
	allocated
}

__global (
	gc_churn_base u64 // metric reading at the last churn collect (baseline)
	gc_churn_busy u32 // single-collector window claim across reactor threads
)

// gc_collect_if_churned forces a collection at a HOST SAFEPOINT iff `metric` has
// advanced by >= `threshold` bytes since the last churn collect. Returns true if
// it collected. `threshold == 0` disables it.
//
// This is an OPT-IN second trigger, additive to (and independent of) the vgc
// auto-pacer's heap_live/next_gc throughput pacing, which is left unchanged. It
// exists for transient-heavy / small-live-set workloads (cx-private #57/#131/#52)
// where the live-set pacer never fires while committed pages — and thus RSS —
// climb. Call it at a natural boundary (end of an HTTP request, a stream chunk),
// NEVER on the allocation hot path: a collect mid-request both mistimes
// reclamation and serializes peer mutators behind the STW pause.
pub fn gc_collect_if_churned(threshold u64, metric GcChurnMetric) bool {
	if threshold == 0 {
		return false
	}
	$if vgc ? {
		cur := if metric == .allocated {
			C.vgc_atomic_load_u64(&vgc_heap.total_alloc)
		} else {
			u64(vgc_memory_use())
		}
		base := C.vgc_atomic_load_u64(&gc_churn_base)
		if cur < base + threshold {
			return false
		}
		// Claim the window so peer reactor threads that crossed the same delta
		// don't all collect at once; the loser just returns and re-checks next
		// safepoint against the rebased baseline.
		mut expected := u32(0)
		if !C.vgc_atomic_cas_u32(&gc_churn_busy, &expected, u32(1)) {
			return false
		}
		gc_collect()
		// Rebase to a post-collect reading of the SAME metric. total_alloc is
		// monotonic, so this advances the window past the bytes just reclaimed;
		// arenas.used does not shrink on sweep, so for .committed this ~equals
		// `cur` — both are correct for delta-gating.
		newbase := if metric == .allocated {
			C.vgc_atomic_load_u64(&vgc_heap.total_alloc)
		} else {
			u64(vgc_memory_use())
		}
		C.vgc_atomic_store_u64(&gc_churn_base, newbase)
		C.vgc_atomic_store_u32(&gc_churn_busy, u32(0))
		return true
	} $else {
		// Non-vgc (boehm / none): only committed bytes are observable. `metric`
		// is accepted for source compatibility; .allocated degrades to committed.
		cur := u64(gc_memory_use())
		if cur < gc_churn_base + threshold {
			return false
		}
		gc_churn_base = cur
		gc_collect()
		gc_churn_base = u64(gc_memory_use())
		return true
	}
}
