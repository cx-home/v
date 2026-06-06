module builtin

// cx_region — scope-aware per-thread region allocator over Boehm. EXPERIMENTAL,
// gated behind `-d cx_regions`; with the flag absent this file is inert and V's
// allocator is unchanged. With the flag present but no scope ever activated
// (cx_region_enter never called), behaviour is ALSO identical to default — the
// malloc hook only diverges while a scope is active.
//
// See bench/parallel-alloc/INTEGRATION-DESIGN.md for the full model. Mechanism
// (validated by bench/parallel-alloc/region.c): one raw (libc) block per thread,
// registered as a GC ROOT once via GC_add_roots (correct use — keeps region→GC
// pointers traced without making the block GC-heap-managed), bump-allocated while
// a scope is active, reset (offset→0, block reused) at scope exit AFTER the
// scope's result has been deep-copied to the GC heap. Transient allocations never
// touch the GC heap, so there is no per-alloc global lock and no conservative-scan
// tax (the block stays small and is reset).

fn C.GC_add_roots(voidptr, voidptr)

const cx_region_block_size = isize(2) << 20 // 2 MiB per thread
const cx_region_max_obj = isize(8) * 1024   // objects larger than this stay on GC

@[thread_local]
__global g_cx_region_blk = &u8(unsafe { nil })
@[thread_local]
__global g_cx_region_cap = isize(0)
@[thread_local]
__global g_cx_region_off = isize(0)
@[thread_local]
__global g_cx_region_depth = int(0)
@[thread_local]
__global g_cx_region_active = false
// count of in-scope allocations that overflowed the block and fell back to GC
// (diagnostic — a high count means the block is too small for the workload).
@[thread_local]
__global g_cx_region_overflow = u64(0)

// cx_region_is_active reports whether the calling thread is inside a region scope.
@[inline]
pub fn cx_region_is_active() bool {
	return g_cx_region_active
}

// cx_region_enter opens (or re-enters) the calling thread's region scope. Nested
// enters share the thread block; only the outermost exit resets it. The block is
// created + GC-rooted lazily on first enter.
pub fn cx_region_enter() {
	$if cx_regions ? {
		if g_cx_region_blk == unsafe { nil } {
			// Raw (libc) block, registered as a GC root once. NOT GC-managed.
			nb := unsafe { &u8(C.malloc(usize(cx_region_block_size))) }
			if nb != unsafe { nil } {
				C.GC_add_roots(voidptr(nb), voidptr(unsafe { nb + cx_region_block_size }))
				g_cx_region_blk = nb
				g_cx_region_cap = cx_region_block_size
			}
		}
		g_cx_region_depth++
		if g_cx_region_blk != unsafe { nil } {
			g_cx_region_active = true
		}
	}
}

// cx_region_exit closes one scope level. The OUTERMOST exit resets the block
// (offset→0, reused). The caller MUST have already deep-copied any value that
// outlives the scope to the GC heap (see cx_region_export in module code) — after
// the reset, region pointers are dangling.
pub fn cx_region_exit() {
	$if cx_regions ? {
		if g_cx_region_depth > 0 {
			g_cx_region_depth--
		}
		if g_cx_region_depth == 0 {
			g_cx_region_active = false
			g_cx_region_off = 0
		}
	}
}

// cx_region_owns reports whether `p` points into the current region block (used
// by realloc to avoid GC_REALLOC on an interior region pointer).
@[inline]
fn cx_region_owns(p voidptr) bool {
	b := g_cx_region_blk
	if b == unsafe { nil } {
		return false
	}
	pi := usize(p)
	lo := usize(b)
	hi := usize(unsafe { b + g_cx_region_cap })
	return pi >= lo && pi < hi
}

// cx_region_block_end returns one-past-the-end of the current block (for bounding
// a realloc copy of a region pointer whose exact size is unknown).
@[inline]
fn cx_region_block_end() voidptr {
	return voidptr(unsafe { g_cx_region_blk + g_cx_region_cap })
}

// cx_region_realloc_to_gc moves a region-owned block to a fresh GC allocation of
// `n` bytes (never GC_REALLOC an interior region pointer), copying the bytes that
// are safely within the current block when the exact old size is unknown.
fn cx_region_realloc_to_gc(b &u8, n isize) &u8 {
	np := &u8(C.GC_MALLOC(n))
	avail := isize(usize(cx_region_block_end()) - usize(b))
	mut cpy := n
	if avail < cpy {
		cpy = avail
	}
	if cpy > 0 {
		unsafe { C.memcpy(np, b, cpy) }
	}
	return np
}

// cx_region_alloc bump-allocates `n` (caller guarantees active && n<=max_obj &&
// n>0). Returns zeroed memory (the libc block is not pre-zeroed, so we zero the
// handed-out span to preserve V's `malloc` zeroing contract). Falls back to
// GC_MALLOC on block overflow (always correct, just not lock-free).
@[inline]
fn cx_region_alloc(n isize) &u8 {
	asize := (n + 15) & ~(isize(15))
	if g_cx_region_off + asize > g_cx_region_cap {
		g_cx_region_overflow++
		return &u8(C.GC_MALLOC(n))
	}
	p := unsafe { g_cx_region_blk + g_cx_region_off }
	g_cx_region_off += asize
	unsafe { C.memset(p, 0, n) }
	return p
}
