// vgc_arena_owner_test.v — one arena tail per allocating thread
// (cx-examples#403).
//
// Two threads take turns allocating 1 MB pointer-free buffers. With first-fit
// carving both take their spans from the same arena's tail, interleaved, so
// their first touches of fresh pages alternate inside one mapping; on macOS
// those faults serialize in the kernel, and 28 xlsx parses in one process read
// 24 s of system time against 1.5 s for 12. With one tail per thread
// (vgc_arena_owner_on, the default) no arena holds both threads' carves.
// The first phase switches the rule off and shows the interleave this test
// would miss; the second switches it back on.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_arena_owner_test.v
module main

import sync.stdatomic

const piece = 1024 * 1024
const pieces = 24 // each thread: 24 MB, both fit one 64 MB arena's tail

struct Turn {
mut:
	n u64
}

// Carves holds one thread's buffers (on the heap: a spawned thread's array
// argument is a copy).
struct Carves {
mut:
	ps []voidptr
}

fn carve(mut turn Turn, me u64, mut out Carves) {
	for _ in 0 .. pieces {
		for stdatomic.load_u64(&turn.n) % 2 != me {
		}
		out.ps << unsafe { malloc_noscan(piece) }
		stdatomic.add_u64(&turn.n, 1)
	}
}

// arenas_in_both answers how many arenas hold carves of both threads.
fn arenas_in_both() (int, []voidptr, []voidptr) {
	mut turn := &Turn{}
	mut ca := &Carves{}
	mut cb := &Carves{}
	ta := spawn carve(mut turn, 0, mut ca)
	tb := spawn carve(mut turn, 1, mut cb)
	ta.wait()
	tb.wait()
	a := ca.ps
	b := cb.ps
	mut in_a := map[int]bool{}
	for p in a {
		in_a[vgc_arena_index_of(p)] = true
	}
	mut both := map[int]bool{}
	for p in b {
		i := vgc_arena_index_of(p)
		assert i >= 0
		if in_a[i] {
			both[i] = true
		}
	}
	return both.len, a, b
}

fn test_two_allocating_threads_never_carve_one_arena_tail() {
	prev := vgc_arena_owner_set(false)
	assert prev, 'the rule is on by default'
	off, a0, b0 := arenas_in_both()
	assert off > 0, 'first fit interleaves the two threads in one arena'
	vgc_arena_owner_set(true)
	on, a1, b1 := arenas_in_both()
	assert on == 0, 'one tail per thread: no arena holds both threads carves'
	// the buffers stay reachable until here, so no carve reused a freed span
	assert a0.len + b0.len + a1.len + b1.len == 4 * pieces
}
