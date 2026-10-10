// chain.v — N relay threads over rendezvous channels, the shape of Go's
// test/chan/goroutines.go and of cx-core-code#116's worker chain: relay i
// receives from its right-hand channel and sends what it got to its left-hand
// one; a first thread sends 1 into the rightmost channel and main receives it
// from the leftmost. Every relay allocates at its entry (a cx worker builds its
// frame before it parks), so each one is a registered mutator holding a GC
// pointer only in its own frame while it is parked.
//
//   N=10000 ./chain            the chain; prints ok=true and the wall time
//   N=4096 GCS=5 ./chain       with every relay parked, GCS forced collections,
//                              each timed: the stop-the-world pause over N
//                              parked threads (min / mean us)
//   WATCHDOG_S=120             exit 3 with a message when nothing completes in time
module main

import os
import sync
import time

struct Frame {
mut:
	id  int
	tag string
	pad [6]u64
}

fn relay(l chan int, r chan int, i int, mut wg sync.WaitGroup) {
	f := &Frame{
		id:  i
		tag: 'relay-${i}'
	}
	wg.done()
	v := <-r
	// f must have survived every collection forced while this thread was parked
	if f.id != i || f.tag != 'relay-${i}' {
		eprintln('chain: relay ${i} read a swept frame: id=${f.id} tag=${f.tag}')
		exit(4)
	}
	l <- v
}

fn first(r chan int) {
	r <- 1
}

fn main() {
	n := os.getenv_opt('N') or { '1000' }.int()
	gcs := os.getenv_opt('GCS') or { '0' }.int()
	watchdog := os.getenv_opt('WATCHDOG_S') or { '120' }.int()
	spawn fn (s int) {
		time.sleep(s * time.second)
		eprintln('chain: no progress in ${s} s (N from the environment)')
		exit(3)
	}(watchdog)
	t0 := time.now()
	left := chan int{}
	mut right := left
	mut wg := sync.new_waitgroup()
	wg.add(n)
	mut ths := []thread{cap: n}
	for i in 1 .. n + 1 {
		r := chan int{}
		ths << spawn relay(right, r, i, mut wg)
		right = r
	}
	wg.wait()
	t_spawned := time.now()
	mut pause_min := i64(-1)
	mut pause_sum := i64(0)
	for _ in 0 .. gcs {
		g0 := time.now()
		gc_collect()
		d := (time.now() - g0).microseconds()
		pause_sum += d
		if pause_min < 0 || d < pause_min {
			pause_min = d
		}
	}
	t_gc := time.now()
	spawn first(right)
	v := <-left
	ths.wait()
	t_end := time.now()
	mut s := 'chain N=${n} ok=${v == 1} wall_ms=${(t_end - t0).milliseconds()} spawn_ms=${(t_spawned - t0).milliseconds()} relay_ms=${(t_end - t_gc).milliseconds()}'
	if gcs > 0 {
		s += ' gcs=${gcs} pause_min_us=${pause_min} pause_mean_us=${pause_sum / gcs}'
	}
	println(s)
	if v != 1 {
		exit(1)
	}
}
