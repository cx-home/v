// vgc_acct_flush_late_threads_test.v — threads that start after a cycle only
// one thread allocated in still reach the pacer (cx-home/v#77 bar (b): a
// daemon at 110 connections ran 0 collections against a 256 KB headroom).
//
// The per-thread accounting flush is set at each stop: 1 MB when at most one
// thread allocated 64 KB or more in the cycle before (vgc_acct_flush), else a
// sixteenth of the budget, at least 64 KB (cx-home/v#56). A program whose
// start-up is one thread therefore leaves the 1 MB flush in force when its
// workers arrive, and n workers each allocating under 1 MB of garbage hold all
// of it unflushed: heap_live never moves, so the trigger never fires however
// far past the goal the arenas carve.
//
// Shape: a collection with the main thread alone, then 32 workers each
// allocate ~896 KB of 64 B garbage and park (alive, so nothing is flushed at
// exit). The bar: at least one collection ran while the workers allocated
// (32 x 896 KB = 28 MB against a sub-MB budget). The carved KB are printed,
// not bounded: under a loaded box the collector runs late and the workers
// carve on past the goal while it does (25,768 KB of 28,672 read once at
// load 16, against 9,480 alone).
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_acct_flush_late_threads_test.v
module main

const nworkers = 32
const per_worker = 896 * 1024
const obj = 64

struct Node {
	next &Node = unsafe { nil }
	pad  [6]u64
}

// churn allocates per_worker bytes of 64 B nodes in chains of 256 that it drops
// (garbage the collector must find; nothing is freed explicitly)
fn churn(ready chan int, release chan int) {
	mut sink := 0
	for _ in 0 .. per_worker / obj / 256 {
		mut head := &Node(unsafe { nil })
		for _ in 0 .. 256 {
			head = &Node{
				next: head
			}
		}
		sink += int(head.pad[0])
	}
	ready <- (sink & 1)
	_ := <-release
}

fn test_late_threads_reach_the_pacer_after_a_one_thread_cycle() {
	ready := chan int{cap: nworkers}
	release := chan int{}
	gc_collect()
	gc_collect()
	before := gc_cycles()
	mem0 := i64(gc_memory_use())
	mut threads := []thread{cap: nworkers}
	for _ in 0 .. nworkers {
		threads << spawn churn(ready, release)
	}
	for _ in 0 .. nworkers {
		_ := <-ready
	}
	during := gc_cycles() - before
	carved := (i64(gc_memory_use()) - mem0) / 1024
	for _ in 0 .. nworkers {
		release <- 1
	}
	threads.wait()
	eprintln('workers=${nworkers} garbage=${nworkers * per_worker / 1024} KB collections_during=${during} carved=${carved} KB')
	assert during >= 1, '${nworkers} late threads allocated ${nworkers * per_worker / 1024} KB of garbage and the pacer ran no collection (each held it under the 1 MB flush)'
}
