// vgc_cold_class_pack_test.v — threads that allocate at the same time do not
// each take a private span per size class for their first few objects
// (cx-home/v#77, piece (a): the plain probe at K=20).
//
// Shape: 64 worker threads, all started before any allocates. Each allocates
// one object in each of twenty size classes (16 B .. 2 KB), keeps them live,
// and then spins until every worker has allocated. The spin is not a GC-safe
// region, so no worker flushes its cached spans (cx-home/v#36) before the
// others take theirs. This is the probe's situation (200 threads start, each
// keeps K strings live, then blocks): each thread takes a fresh 8 KB span per
// class it touches, so twenty live objects pin twenty nearly empty spans per
// thread, and a non-moving collector cannot pack them afterwards. The v#77
// net-wait flush (6e4d67cce7) does not reach this case.
//
// The bar (v#77): the probe at K=20 reads within 10 % of -gc none. Here that
// is the carve over the workers' live bytes, which must stay under 2x, the
// bound the sibling park tests use. It reads about 16x before the fix. The fix
// lets a thread's first objects of a cold class go into a span shared under the
// class's central lock. It gets a private cached span only once the class is
// warm for that thread.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_cold_class_pack_test.v
module main

import sync.stdatomic

const nthreads = 64
const sizes = [16, 24, 32, 48, 64, 80, 96, 128, 160, 192, 256, 320, 384, 512, 640, 768, 1024,
	1280, 1536, 2048]

struct Held {
mut:
	bufs [][]u8
}

fn worker(start chan int, done &u64, ready chan int, release chan int, mut held Held) {
	_ := <-start
	mut keep := [][]u8{cap: sizes.len}
	for sz in sizes {
		keep << []u8{len: sz, init: u8(sz)}
	}
	held.bufs = keep
	stdatomic.add_u64(done, 1)
	// spin, not park: no safe region, so no flush before every worker has carved
	for stdatomic.load_u64(done) < u64(nthreads) {
	}
	ready <- 1
	_ := <-release
}

fn test_concurrent_cold_classes_share_spans() {
	start := chan int{}
	ready := chan int{}
	release := chan int{}
	mut done := u64(0)
	mut helds := []&Held{cap: nthreads}
	mut threads := []thread{cap: nthreads}
	for _ in 0 .. nthreads {
		mut h := &Held{}
		helds << h
		threads << spawn worker(start, &done, ready, release, mut h)
	}
	gc_collect()
	before := gc_memory_use()
	start.close()
	for _ in 0 .. nthreads {
		_ := <-ready
	}
	gc_collect()
	after := gc_memory_use()
	mut live := 0
	for h in helds {
		for b in h.bufs {
			live += b.len
		}
	}
	for _ in 0 .. nthreads {
		release <- 1
	}
	threads.wait()
	carved := i64(after) - i64(before)
	ratio := f64(carved) / f64(live)
	eprintln('workers=${nthreads} classes=${sizes.len} live=${live} B carved=${carved} B (${carved / 1024} KB) ratio=${ratio:.1f}')
	assert ratio < 2.0, 'concurrently started threads took a private span per cold class: ${carved} B carved for ${live} B live (${ratio:.1f}x)'
}
