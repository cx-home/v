// churn.v — threads that allocate and exit while another thread forces a
// collection every millisecond (cx-home/v#28). An exiting thread runs its
// pthread-key destructors — the collector's exit callback among them — and
// waits there for cache_lock while a cycle holds it; the cycle's suspend
// signal reaches it in that wait. Under the pthread-key TLS (tcc) its cache
// index is already cleared by then, so a handler that found its record only
// through that index never acked and the collector waited for ever.
//
//   WAVES=200 PER_WAVE=16 ./churn    exit 0 and a line when every wave joined
//   WATCHDOG_S=60                     exit 3 with a message on no progress
module main

import os
import time

struct Rec {
mut:
	id  int
	pad [5]u64
}

fn worker(id int) int {
	mut sum := 0
	for k in 0 .. 64 {
		r := &Rec{
			id: id + k
		}
		sum += r.id
	}
	return sum
}

fn forcer(stop &bool) {
	for !*stop {
		gc_collect()
		time.sleep(1 * time.millisecond)
	}
}

fn main() {
	waves := os.getenv_opt('WAVES') or { '200' }.int()
	per := os.getenv_opt('PER_WAVE') or { '16' }.int()
	watchdog := os.getenv_opt('WATCHDOG_S') or { '60' }.int()
	spawn fn (s int) {
		time.sleep(s * time.second)
		eprintln('churn: no progress in ${s} s')
		// _exit: exit() runs the collector's exit path, which a wedged stop
		// blocks — the cx-home/v#43 hang outlived this watchdog for 4 h
		C._exit(3)
	}(watchdog)
	mut stop := false
	f := spawn forcer(&stop)
	t0 := time.now()
	mut total := i64(0)
	for w in 0 .. waves {
		mut ths := []thread int{cap: per}
		for i in 0 .. per {
			ths << spawn worker(w * per + i)
		}
		for s in ths.wait() {
			total += s
		}
	}
	stop = true
	f.wait()
	println('churn waves=${waves} per_wave=${per} ok total=${total} wall_ms=${(time.now() - t0).milliseconds()} cycles=${gc_cycles()}')
}
