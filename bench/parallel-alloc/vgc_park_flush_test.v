// vgc_park_flush_test.v — a thread that parks gives up its cached spans
// (cx-home/v#36).
//
// Shape: 400 worker threads start one after another. Each allocates three
// objects in each of eight size classes (16 B .. 2 KB), keeps them live, then
// parks on a channel receive, which is a GC-safe region. Before the fix every
// parked thread kept the span it had cached for each class, a few objects
// into 8 KB, and the next thread carved fresh ones. cx's chain of 10,000
// parked workers held 1.25 GB against a 63 MB live set. A thread entering a
// safe region now hands its partly used spans to central.partial (once per
// cycle), so the next thread refills from them. The carve over the workers'
// live bytes must stay under 2x (6.7x before the fix: 32 MB for 4.9 MB; 1.2x after).
//
// Run: ./v test bench/parallel-alloc/vgc_park_flush_test.v
module main

const nthreads = 400
const sizes = [16, 32, 64, 128, 256, 512, 1024, 2048]

struct Held {
mut:
	bufs [][]u8
}

fn worker(ready chan int, release chan int, mut held Held) {
	mut keep := [][]u8{cap: 3 * sizes.len}
	for sz in sizes {
		for k in 0 .. 3 {
			keep << []u8{len: sz, init: u8(k)}
		}
	}
	held.bufs = keep
	ready <- 1
	_ := <-release
}

fn test_parked_threads_do_not_keep_their_cached_spans() {
	ready := chan int{}
	release := chan int{}
	mut helds := []&Held{cap: nthreads}
	gc_collect()
	before := gc_memory_use()
	mut threads := []thread{cap: nthreads}
	for _ in 0 .. nthreads {
		mut h := &Held{}
		helds << h
		threads << spawn worker(ready, release, mut h)
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
	eprintln('workers=${nthreads} live=${live} B carved=${carved} B (${carved / 1024} KB) ratio=${ratio:.1f}')
	assert ratio < 2.0, 'parked threads kept their cached spans: ${carved} B carved for ${live} B live (${ratio:.1f}x)'
}
