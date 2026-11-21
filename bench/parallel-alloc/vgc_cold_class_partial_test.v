// vgc_cold_class_partial_test.v — the cold-class carve fills the spans that
// blocked threads handed back before it carves a fresh one (cx-home/v#77,
// the plain probe at K=20).
//
// Shape: the probe's start-up. thr.v spawns 200 threads that each keep K
// strings of different size classes and then block on a channel. The first
// few threads run while fewer than vgc_cold_min_threads (8) are live, so each
// takes a private span per class for its one object (cx-core-code#295 keeps
// a program with a few threads off the shared span). When they block, the
// safe-region flush (cx-home/v#36) puts those nearly empty spans on their
// class's central.partial list. The threads after them carve the class's
// shared span — and that carve took a fresh span, never the partial ones, so
// the first threads' spans stayed one object full: about 640 KB of the
// probe's 5 MB at K=20 on pbm1, 1.20x of -gc none where the bar is 1.10.
//
// Here: five early workers (six live threads), one at a time, allocate one
// object in each of twenty classes and block; then 59 workers, all started
// together, do the same. The bar: at least 40 % of the late objects sit in a
// span an early worker took (0 of 1,180 before the fix: the shared span was always
// fresh; 627 of 1,180 after it, on pbm1: the late objects fill the early
// spans' free slots first, and the rest overflow the large classes' few).
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_cold_class_partial_test.v
module main

import time

const early = 5
const late = 59
const sizes = [16, 24, 32, 48, 64, 80, 96, 128, 160, 192, 256, 320, 384, 512, 640, 768, 1024,
	1280, 1536, 2048]

struct Held {
mut:
	bufs [][]u8
}

fn fill(mut held Held) {
	mut keep := [][]u8{cap: sizes.len}
	for sz in sizes {
		keep << []u8{len: sz, init: u8(sz)}
	}
	held.bufs = keep
}

// An early worker allocates first: its first blocking operation is then the
// pop below, so its safe-region flush (once a cycle) hands back the spans it
// just took, as thr.v's threads do.
fn early_worker(ready chan int, release chan int, mut held Held) {
	fill(mut held)
	ready <- 1
	_ := <-release
}

// The late workers wait on one start so all of them are live before any
// allocates (each then carves from the shared span).
fn late_worker(start chan int, ready chan int, release chan int, mut held Held) {
	_ := <-start
	fill(mut held)
	ready <- 1
	_ := <-release
}

fn start_early(ready chan int, release chan int, mut helds []&Held, mut threads []thread) {
	for _ in 0 .. early {
		mut h := &Held{}
		helds << h
		threads << spawn early_worker(ready, release, mut h)
		// one at a time: fewer than vgc_cold_min_threads are live while each allocates
		_ := <-ready
	}
}

fn start_late(ready chan int, release chan int, mut helds []&Held, mut threads []thread) {
	start := chan int{}
	for _ in 0 .. late {
		mut h := &Held{}
		helds << h
		threads << spawn late_worker(start, ready, release, mut h)
	}
	start.close()
	for _ in 0 .. late {
		_ := <-ready
	}
}

fn test_cold_carve_fills_the_spans_blocked_threads_handed_back() {
	ready := chan int{}
	release := chan int{}
	mut helds := []&Held{cap: early + late}
	mut threads := []thread{cap: early + late}
	start_early(ready, release, mut helds, mut threads)
	// the early workers reach their blocking pop (and flush) before the late ones start
	time.sleep(100 * time.millisecond)
	start_late(ready, release, mut helds, mut threads)
	// the spans the early workers' objects sit in, by class
	mut early_spans := map[u64]bool{}
	for h in helds[..early] {
		for b in h.bufs {
			early_spans[u64(vgc_find_span_addr(b.data))] = true
		}
	}
	mut filled := 0
	mut total := 0
	for h in helds[early..] {
		for b in h.bufs {
			total++
			if u64(vgc_find_span_addr(b.data)) in early_spans {
				filled++
			}
		}
	}
	for _ in 0 .. early + late {
		release <- 1
	}
	threads.wait()
	share := f64(filled) / f64(total)
	eprintln('early=${early} late=${late} classes=${sizes.len}: ${filled} of ${total} late objects in an early span (${share * 100:.0f} %)')
	assert share >= 0.4, 'the cold carve took fresh spans past the early threads\' partial ones: ${filled} of ${total} late objects in an early span'
}
