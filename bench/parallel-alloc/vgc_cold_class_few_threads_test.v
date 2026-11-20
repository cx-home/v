// vgc_cold_class_few_threads_test.v — a program with a few threads does not
// pay the cold-class carve (cx-core-code#295, beside vgc_cold_class_main_test).
//
// Shape: three workers, started together, each allocate three objects in each
// of twenty size classes (16 B .. 2 KB) and keep them until all three are done.
// The v#77 cold-class carve gives a thread's first two objects of a class to
// the class's shared span and its third to a private span of its own, so a few
// threads that each warm their classes carve the shared spans on top of their
// own: four spans a class for three threads. That packing pays only when many
// threads start together (vgc_cold_class_pack_test: 64); with a few threads it
// is one more page a class touched (`cx --version`: a main thread and a helper,
// +96 KB resident after the main thread alone started warm).
//
// The bar: the carve stays under one span (8 KB) a class a thread plus a
// quarter.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_cold_class_few_threads_test.v
module main

import sync.stdatomic

const nthreads = 3
const sizes = [16, 24, 32, 48, 64, 80, 96, 128, 160, 192, 256, 320, 384, 512, 640, 768, 1024,
	1280, 1536, 2048]

struct Held {
mut:
	bufs [][]u8
}

fn worker(start chan int, done &u64, ready chan int, release chan int, mut held Held) {
	_ := <-start
	mut keep := [][]u8{cap: 3 * sizes.len}
	for sz in sizes {
		for k in 0 .. 3 {
			keep << []u8{len: sz, init: u8(sz + k)}
		}
	}
	held.bufs = keep
	stdatomic.add_u64(done, 1)
	for stdatomic.load_u64(done) < u64(nthreads) {
	}
	ready <- 1
	_ := <-release
}

fn test_few_threads_take_one_span_per_class_each() {
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
	for _ in 0 .. nthreads {
		release <- 1
	}
	threads.wait()
	carved := i64(after) - i64(before)
	per := carved / i64(nthreads * sizes.len)
	eprintln('workers=${nthreads} classes=${sizes.len} carved=${carved} B (${per} B a class a thread)')
	assert per <= 8192 + 2048, 'a few threads carved ${per} B a class each (the shared spans on top of their own)'
}
