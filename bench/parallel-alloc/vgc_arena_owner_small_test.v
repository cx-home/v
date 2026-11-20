// vgc_arena_owner_small_test.v — a thread that allocated little carves the
// shared arena tail; only a thread that allocated a working set takes an arena
// tail of its own (cx-private#2056, the worker-chain-channels memory row).
//
// One arena tail per allocating thread (cx-examples#403) is for threads that
// each first-touch a working set: 28 xlsx parses first-touching 1 MB pieces of
// shared mappings spent 26 s of system time where mappings of their own spent
// 4 s. A program of thousands of parked workers (cx's [?worker] chain over
// rendezvous channels, N = 4,000 and 10,000) allocates a few KB on each, and
// every one of them claimed a fresh arena tail: each worker's first span sat
// alone in its own pages, ~10 KB of resident memory per worker (dev2 11-19:
// cx at N = 4,000 read 233.5 MB peak RSS, 192.5 MB with VGC_ARENA_OWNER=0;
// Python 178.5 MB). The spec: a thread takes an arena tail of its own once it
// allocated vgc_arena_owner_min bytes (1 MB); below that it carves first fit.
//
// Run: ./v test bench/parallel-alloc/vgc_arena_owner_small_test.v
module main

import sync

const nthreads = 256

fn small(mut wg sync.WaitGroup, mut gate sync.WaitGroup) int {
	// a few KB in a few size classes: a parked worker's start
	mut keep := [][]u8{}
	for i in 0 .. 8 {
		keep << []u8{len: 64 + 96 * i}
	}
	wg.done()
	gate.wait()
	return keep.len
}

fn test_small_threads_share_the_arena_tail() {
	mut wg := sync.new_waitgroup()
	mut gate := sync.new_waitgroup()
	wg.add(nthreads)
	gate.add(1)
	mut ts := []thread int{}
	for _ in 0 .. nthreads {
		ts << spawn small(mut wg, mut gate)
	}
	wg.wait()
	// every thread allocated and is parked, its spans still cached
	arenas := vgc_arena_count()
	gate.done()
	for t in ts {
		assert t.wait() == 8
	}
	// a few KB on each of 256 threads is well under one 64 MB arena: first
	// fit needs one or two; an arena tail per thread maps one per thread
	assert arenas <= 2, '${arenas} arenas for ${nthreads} threads of a few KB each (first fit: 1-2)'
}
