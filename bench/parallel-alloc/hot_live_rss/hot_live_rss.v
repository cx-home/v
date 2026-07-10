// hot_live_rss — cx #272 CX-free reproducer + pacing A/B harness.
//
// The #71 companion (hot_loop_rss.v) measures the allocate/discard extreme:
// O(1) live set, so every cycle's mark is near-free and the only question is
// how much dead transient the pacer lets pile up. This bench measures the
// OTHER operating point — the one the xap-marine helm wedged on: a LARGE
// pinned live set (hundreds of MB to GB) under the same transient churn. There
// every backstop cycle pays a full mark of the live graph, so the pause is
// expensive and roughly constant; the pacer headroom decides only how OFTEN
// that fixed price is paid.
//
// The live set is a pointer-dense graph (arrays of split-up strings) so the
// mark phase really walks it — a flat byte blob would understate mark cost.
//
// Usage:
//   ./v -gc e -prod -o /tmp/hotlive_e bench/parallel-alloc/hot_live_rss/hot_live_rss.v
//   /tmp/hotlive_e [nthreads] [iters_per_thread] [live_mb]
//   VGC_GCTRACE=1 /tmp/hotlive_e 4 2000000 2048   # per-cycle pause trace
//
// Prints ops/s, worker-observed max single-iteration stall (the latency
// proxy a wedged HTTP client sees), GC-visible RSS.
module main

import os
import time

struct WRes {
	acc   u64
	// max wall time of ONE iteration, µs. A GC STW lands inside some
	// iteration; on a large live set that iteration's wall time IS the pause
	// the request path would observe.
	worst u64
}

fn build_live_set(live_mb int) [][]string {
	// ~1 KiB of string payload per row, split into parts so the graph is
	// pointer-dense: row array -> parts array -> string headers -> buffers.
	rows := live_mb * 1024
	mut root := [][]string{cap: rows}
	for i in 0 .. rows {
		mut payload := 'live-${i}'
		for payload.len < 1024 {
			payload += '-abcdefghijklmnopqrstuvwxyz0123456789'
		}
		root << payload.split('-')
	}
	return root
}

fn worker(iters int, tid int) WRes {
	mut acc := u64(0)
	mut worst := u64(0)
	for i in 0 .. iters {
		it0 := time.sys_mono_now()
		// Same representative transient mix as hot_loop_rss.v (comparability).
		s := 'transient-${tid}-${i}-payload'
		parts := s.split('-')
		acc += u64(parts.len) + u64(s.len)
		v := i * 3
		t := v.str()
		acc += u64(t.len)
		d := (time.sys_mono_now() - it0) / 1000
		if d > worst {
			worst = d
		}
	}
	return WRes{acc, worst}
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
	mut live_mb := 1024
	if os.args.len > 1 {
		nthreads = os.args[1].int()
	}
	if os.args.len > 2 {
		iters = os.args[2].int()
	}
	if os.args.len > 3 {
		live_mb = os.args[3].int()
	}
	tb0 := time.now()
	// Held in main's frame for the whole run — a conservative stack root, so
	// every backstop cycle marks the full graph (the #272 operating point).
	live := build_live_set(live_mb)
	build_s := time.since(tb0)
	t0 := time.now()
	mut total := u64(0)
	mut worst := u64(0)
	if nthreads == 0 {
		// Inline mode — see hot_loop_rss.v: isolates mark/sweep cost from the
		// STW protocol (no spawned mutators to stop).
		r := worker(iters, 0)
		total = r.acc
		worst = r.worst
	} else {
		mut handles := []thread WRes{}
		for t in 0 .. nthreads {
			handles << spawn worker(iters, t)
		}
		for h in handles {
			r := h.wait()
			total += r.acc
			if r.worst > worst {
				worst = r.worst
			}
		}
	}
	elapsed := time.since(t0)
	nworkers := if nthreads == 0 { 1 } else { nthreads }
	ops := f64(nworkers) * f64(iters) / (f64(elapsed.microseconds()) / 1_000_000.0)
	println('threads=${nthreads} iters/thread=${iters} live_mb=${live_mb} build=${build_s} elapsed=${elapsed} Mops/s=${ops / 1_000_000.0:.2f} worst_stall_ms=${f64(worst) / 1000.0:.1f} acc=${total} live_rows=${live.len} max_rss_kb=${max_rss_kb()}')
}
