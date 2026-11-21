// vgc_thread_tls_malloc_test.v — a thread costs the collector no libc malloc
// block on macOS (cx-home/v#77, the plain probe at K=20).
//
// The collector keeps each thread's cache index in thread-local storage. On
// macOS a __thread variable is a dyld thread-local variable: dyld mallocs the
// image's block (32 B here) on each thread's first access. Nothing else in a
// -gc e program mallocs per thread, so those blocks are the only libc
// allocations the probe's 200 threads make, and the nano allocator spreads
// them over per-CPU blocks: about 350 KB resident on pbm1 (M5 Max), 1.8 KB a
// thread of the 4.0 KB the probe reads over -gc none at K=0. In a pthread key
// the index lives in the thread's own TSD slots (no allocation).
//
// The bar: 64 threads that block add fewer than 16 malloc blocks.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_thread_tls_malloc_test.v
module main

#include <malloc/malloc.h>

struct C.malloc_statistics_t {
	blocks_in_use   u32
	size_in_use     usize
	max_size_in_use usize
	size_allocated  usize
}

fn C.malloc_zone_statistics(zone voidptr, stats &C.malloc_statistics_t)

const nthreads = 64

fn blocks() u32 {
	st := C.malloc_statistics_t{}
	C.malloc_zone_statistics(unsafe { nil }, &st)
	return st.blocks_in_use
}

fn idle(ready chan int, release chan int) {
	mut keep := []string{}
	keep << 'x'.repeat(40)
	ready <- 1
	_ := <-release
	_ = keep.len
}

fn test_a_thread_costs_no_malloc_block() {
	$if !macos {
		return
	}
	ready := chan int{}
	release := chan int{}
	mut threads := []thread{cap: nthreads}
	// one thread first, so the channel's and the spawn path's one-time setup is done
	threads << spawn idle(ready, release)
	_ := <-ready
	before := blocks()
	for _ in 1 .. nthreads {
		threads << spawn idle(ready, release)
	}
	for _ in 1 .. nthreads {
		_ := <-ready
	}
	after := blocks()
	for _ in 0 .. nthreads {
		release <- 1
	}
	threads.wait()
	added := i64(after) - i64(before)
	eprintln('threads=${nthreads - 1} malloc blocks added=${added}')
	assert added < 16, '${nthreads - 1} threads added ${added} malloc blocks (a dyld thread-local block each)'
}
