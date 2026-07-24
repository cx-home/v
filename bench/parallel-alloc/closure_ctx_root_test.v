// closure_ctx_root_test.v — CX-free teeth for the malloc_uncollectable root
// contract under vgc (cx-private #613).
//
// A `fn [captures] (...)` closure stores its captured-context struct (allocated
// via memdup_uncollectable) in the closure's mmap'd metadata page — memory the
// collector NEVER scans (not a stack, not a data segment, not the GC heap). So
// when the closure value is the ONLY holder of that context, nothing the mark
// phase can reach points to it. Pre-fix, `malloc_uncollectable` under vgc was a
// plain collectable vgc_malloc — the first full collection swept every such
// context (and everything reachable only through it, e.g. the interface box a
// `fn [b]` capture holds), and the next closure invocation read freed memory:
// exactly the #613 store-open segfault (the cxpack loader's `getter_of` closure
// died once a 2000-entry journal load grew the heap enough to trigger GC).
// The fix registers uncollectable blocks as pinned GC roots (Boehm's
// GC_MALLOC_UNCOLLECTABLE parity: immortal + scanned).
//
// The teeth need the real bug's conditions, not just one closure + one
// collect: each context's span must be EVICTED from the allocating thread's
// mcache (in-cache spans are sweep-protected by vgc_protect_cached_spans) and
// the swept slots must be REUSED (a stale read of intact freed memory passes).
// Hence: many closures, same-size-class churn between and after, scrubbed
// stack, repeated forced collections.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/closure_ctx_root_test.v
// (also passes under -gc boehm / none — the contract is GC-agnostic).

type GetterFn = fn () string

interface Boxed {
	value() string
}

struct Payload {
	s string
}

fn (p Payload) value() string {
	return p.s
}

// make_getter mirrors the crashing shape (cxstore.getter_of): the interface
// box for `b` is heap-allocated at the call boundary and, after return, is
// reachable ONLY through the closure's captured context.
@[noinline]
fn make_getter(b Boxed) GetterFn {
	return fn [b] () string {
		return b.value()
	}
}

// rotate_mcache allocates a burst of small objects across the ctx-sized
// classes so the spans holding earlier closure contexts leave the mcache
// (only evicted spans are sweepable).
@[noinline]
fn rotate_mcache() []voidptr {
	mut keep := []voidptr{cap: 4096}
	for i in 0 .. 4096 {
		mut b := []u8{len: 16 + (i % 12) * 16, init: u8(i)}
		keep << voidptr(b.data)
	}
	return keep
}

@[noinline]
fn build_closures(n int) []GetterFn {
	mut out := []GetterFn{}
	for i in 0 .. n {
		// runtime-built payload string: lives in GC memory (a literal could be
		// rodata and mask the sweep)
		out << make_getter(Payload{
			s: 'alive-' + '${i}'
		})
		if i % 16 == 15 {
			rotate_mcache()
		}
	}
	return out
}

// scrub_stack overwrites the frames that held the interface box / payload
// pointers during construction, so a conservative stack scan cannot
// accidentally keep the contexts' referents alive and mask the bug.
@[noinline]
fn scrub_stack(depth int) u64 {
	mut noise := [64]u64{}
	for i in 0 .. 64 {
		noise[i] = u64(depth * 31 + i)
	}
	if depth <= 0 {
		return noise[63]
	}
	return noise[0] + scrub_stack(depth - 1)
}

fn test_closure_ctx_survives_collection() {
	closures := build_closures(256)
	assert closures[7]() == 'alive-7'
	scrub_stack(64)
	gc_collect()
	gc_collect()
	// force reuse of any swept slots before reading through the closures
	reuse := rotate_mcache()
	assert reuse.len == 4096
	gc_collect()
	for i, g in closures {
		assert g() == 'alive-${i}'
	}
}
