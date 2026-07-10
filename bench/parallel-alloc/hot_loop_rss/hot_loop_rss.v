// hot_loop_rss — cx #71 CX-free reproducer + pacing A/B harness.
//
// A tight allocate/discard loop whose live set is O(1): every iteration builds
// a few short-lived strings/arrays and drops them. A collector with sane
// pacing keeps RSS bounded (boehm does); the vgc backstop's old policy
// (256 MB floor x live_threads multiplier on the goal) let RSS climb to the
// arena ceiling on multi-threaded runs — the cx #57 field OOM shape.
//
// Usage:
//   v -gc e     -o /tmp/hot_e     bench/parallel-alloc/hot_loop_rss/hot_loop_rss.v
//   v -gc boehm -o /tmp/hot_boehm bench/parallel-alloc/hot_loop_rss/hot_loop_rss.v
//   /tmp/hot_e [nthreads] [iters_per_thread]     # prints ops/s + max RSS
//
// Pass criteria (vgc, post-pacer-fix): max RSS bounded well under the arena
// capacity at any thread count, throughput within noise of the old pacing.
module main

import os
import time

fn worker(iters int, tid int) u64 {
	mut acc := u64(0)
	for i in 0 .. iters {
		// A representative transient mix: interpolation (noscan string buffer),
		// split (array of string structs + buffers), int formatting. All dead by
		// the iteration's end — the live set is `acc` only.
		s := 'transient-${tid}-${i}-payload'
		parts := s.split('-')
		acc += u64(parts.len) + u64(s.len)
		v := i * 3
		t := v.str()
		acc += u64(t.len)
	}
	return acc
}

fn max_rss_kb() i64 {
	// ru_maxrss: bytes on macOS, KB on Linux.
	res := os.execute('ps -o rss= -p ${os.getpid()}')
	if res.exit_code == 0 {
		return res.output.trim_space().i64()
	}
	return -1
}

fn main() {
	mut nthreads := 4
	mut iters := 2_000_000
	if os.args.len > 1 {
		nthreads = os.args[1].int()
	}
	if os.args.len > 2 {
		iters = os.args[2].int()
	}
	t0 := time.now()
	mut total := u64(0)
	if nthreads == 0 {
		// Inline mode: run one worker on the MAIN thread with nothing spawned —
		// the collector sees zero other registered mutators (want=0), so the
		// stop-wait and mach-suspend paths are skipped entirely. Isolates the
		// mark/sweep pause from the STW-protocol cost (#71 pause budgeting).
		total = worker(iters, 0)
	} else {
		mut handles := []thread u64{}
		for t in 0 .. nthreads {
			handles << spawn worker(iters, t)
		}
		for h in handles {
			total += h.wait()
		}
	}
	elapsed := time.since(t0)
	nworkers := if nthreads == 0 { 1 } else { nthreads }
	ops := f64(nworkers) * f64(iters) / (f64(elapsed.microseconds()) / 1_000_000.0)
	println('threads=${nthreads} iters/thread=${iters} elapsed=${elapsed} Mops/s=${ops / 1_000_000.0:.2f} acc=${total} max_rss_kb=${max_rss_kb()}')
}
