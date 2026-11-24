// locale_churn.v — the fixture of vgc_gctrace_stop_safe_test.v (cx-home/v#62): THREADS
// threads each allocate small arrays (collections run all the time) and format an integer
// through libc's snprintf, whose formatter takes libc's locale lock (localeconv_l), ROUNDS
// times; at VGC_GCTRACE=2 every collection writes its trace lines while the world is stopped.
// A worker keeps going past ROUNDS until MIN_CYCLES collections have completed (gc_cycles(),
// read every 1024 rounds), so every collection the test counts ran under the churn whatever the
// pacer's spacing: with cx-private#2040's pacing (f6a5dfee04) the 8 workers finish ROUNDS sooner
// and an 8-core x86 box saw 85-116 collections a run against 168-244 on 377e4407eb.
// It prints the collections it saw complete (gc_cycles()) and `done`.
module main

import os
import time

fn C.snprintf(buf &u8, n usize, fmt &char, ...voidptr) int

fn work(rounds int, min_cycles u64, seed int, out chan u64) {
	mut buf := [64]u8{}
	mut sink := u64(0)
	for i := 0; true; i++ {
		if i >= rounds && i % 1024 == 0 && gc_cycles() >= min_cycles {
			break
		}
		t := []int{len: 64, init: index + i + seed}
		sink += u64(t[i % 64])
		n := unsafe { C.snprintf(&buf[0], 64, c'%d %d', i, seed) }
		sink += u64(n)
	}
	out <- sink
}

// forcer runs a collection every millisecond until the workers finish: the test asks for
// more than 100 collections, and on a loaded box (the 28-job suite) the pacing reads the
// descheduled workers as several allocating threads and spaces its own collections out to
// 60-80 on every build (misc-epic-105/-105b; 27 copies alongside: 60-77 on 51eab410b6 and
// on 1aca2b86a4 alike). Forced stops write the same trace lines under the same stop.
fn forcer(done chan bool) {
	for {
		select {
			_ := <-done {
				return
			}
			else {
				gc_collect()
				time.sleep(time.millisecond)
			}
		}
	}
}

fn main() {
	threads := os.getenv_opt('THREADS') or { '8' }.int()
	rounds := os.getenv_opt('ROUNDS') or { '400000' }.int()
	min_cycles := u64(os.getenv_opt('MIN_CYCLES') or { '150' }.int())
	out := chan u64{cap: threads}
	done := chan bool{cap: 1}
	f := spawn forcer(done)
	mut hs := []thread{}
	for s in 0 .. threads {
		hs << spawn work(rounds, min_cycles, s, out)
	}
	hs.wait()
	done <- true
	f.wait()
	mut total := u64(0)
	for _ in 0 .. threads {
		total += <-out
	}
	println('cycles=${gc_cycles()} sink=${total}')
	println('done')
}
