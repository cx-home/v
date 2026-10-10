// vgc_spawn_roots_many_live_test.v — more than 1,024 spawned threads alive at
// once (cx-core-code#116). Each spawn registers its argument struct as a root
// until the spawned fn returns, and the table was a fixed [1024]: the 1,025th
// live thread's spawn spun forever waiting for a slot (a chain of 2,000 parked
// cx workers hung). The table grows now; every thread's argument stays a root
// across collections forced while they are all parked.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_spawn_roots_many_live_test.v
module main

import os
import sync
import time

const n_threads = 2000

struct Arg {
	id  int
	tag string
}

fn parked(a &Arg, mut wg sync.WaitGroup, gate chan bool, out chan string) {
	wg.done()
	_ := <-gate
	// the argument must have survived the collections forced while parked
	out <- '${a.id}:${a.tag}'
}

fn test_more_than_1024_live_spawned_threads() {
	spawn fn () {
		time.sleep(120 * time.second)
		eprintln('vgc_spawn_roots_many_live_test: no progress in 120 s (spawn-root table full?)')
		exit(3)
	}()
	gate := chan bool{cap: n_threads}
	out := chan string{cap: n_threads}
	mut wg := sync.new_waitgroup()
	wg.add(n_threads)
	for i in 0 .. n_threads {
		a := &Arg{
			id:  i
			tag: 'arg-' + 'x'.repeat(i % 31)
		}
		spawn parked(a, mut wg, gate, out)
	}
	wg.wait()
	for _ in 0 .. 3 {
		mut junk := []string{}
		for j in 0 .. 20000 {
			junk << 'junk-${j}'
		}
		assert junk.len == 20000
		gc_collect()
	}
	for _ in 0 .. n_threads {
		gate <- true
	}
	mut seen := map[int]bool{}
	for _ in 0 .. n_threads {
		s := <-out
		id := s.all_before(':').int()
		assert s.all_after(':') == 'arg-' + 'x'.repeat(id % 31), 'thread ${id} read a swept argument: ${s}'
		seen[id] = true
	}
	assert seen.len == n_threads
	_ = os.getpid()
}
