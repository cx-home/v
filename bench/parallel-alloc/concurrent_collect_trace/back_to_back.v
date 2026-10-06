// back_to_back.v — the fixture of vgc_concurrent_collect_trace_test.v (cx-private
// #1794, #1795), REFUTE-1's flat driver: build LIVE_MB of 4 KB chunks, call
// gc_collect() NCOLLECT times back to back, read gc_heap_usage(), then stream CHURN
// times the live set in 4 KB transients sampling gc_memory_use() every 256; print
// the number of collections the collector completed (gc_cycles()) so the test can
// count the VGC_GCTRACE=1 lines against it.
module main

import os

const chunk = 4096

fn main() {
	live_bytes := os.getenv_opt('LIVE_MB') or { '128' }.int() * 1024 * 1024
	ncollect := os.getenv_opt('NCOLLECT') or { '2' }.int()
	churn := os.getenv_opt('CHURN') or { '4' }.int()
	mut live := [][]u8{cap: live_bytes / chunk}
	for _ in 0 .. live_bytes / chunk {
		live << []u8{len: chunk, init: 7}
	}
	for _ in 0 .. ncollect {
		gc_collect()
	}
	marked := gc_heap_usage().total_bytes
	mut high := gc_memory_use()
	mut sink := u64(0)
	for i in 0 .. churn * live_bytes / chunk {
		t := []u8{len: chunk, init: u8(i)}
		sink += t[i % chunk]
		if i % 256 == 0 {
			c := gc_memory_use()
			if c > high {
				high = c
			}
		}
	}
	for c in live {
		if c[chunk - 1] != 7 {
			println('bad: a live chunk changed')
			exit(1)
		}
	}
	println('cycles=${gc_cycles()} ratio=${f64(high) / f64(live_bytes):.3f} marked=${marked} sink=${sink} kept=${live.len}')
}
