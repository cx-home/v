// vgc_worker_chain_test.v — thousands of live registered threads at once, each
// parked on a rendezvous channel while holding a GC pointer only in its frame
// (cx-home/v#27, v#28, cx-core-code#116).
//
// The mutator slot table was a fixed caches[1024] inside vgc_heap: the 1,025th
// simultaneously live thread waited forever in vgc_register_thread (0x0ac7
// once a second) — a chain of 2,000 cx workers hung at ~1,600 % CPU — and the
// stop-the-world signal-suspended every parked thread one ack at a time. The
// table grows in chunks now, slots are reused through a free list, the
// collector's walks run to the high-water mark, the suspend is two passes
// (request all, then settle all), and a thread parked in a semaphore wait is
// a GC-safe region that needs no suspend at all.
//
// worker_chain/chain.v is the fixture (Go's test/chan/goroutines.go shape).
// Red on 66580d4028 (bump C): N=2000 hangs until the fixture's watchdog
// (exit 3); green with the fix: N=10000 in a few seconds.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_worker_chain_test.v
module main

import os

const chain_sizes = [2000, 4000, 10000]

fn build_fixture() string {
	src := os.join_path(@DIR, 'worker_chain', 'chain.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_worker_chain_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

// FreeBSD caps a process at kern.threads.max_threads_per_proc threads (1,500
// by default): the sizes are clamped there (see vgc_spawn_roots_many_live_test.v).
fn thread_limit() int {
	$if freebsd {
		r := os.execute('sysctl -n kern.threads.max_threads_per_proc')
		if r.exit_code == 0 {
			limit := r.output.trim_space().int()
			if limit > 0 {
				return limit - 64
			}
		}
	}
	return 1 << 30
}

fn test_chain_of_thousands_of_parked_workers() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	limit := thread_limit()
	mut done := []int{}
	for want in chain_sizes {
		n := if want > limit { limit } else { want }
		if n in done {
			continue
		}
		done << n
		assert n > 1024, 'this box allows ${n + 64} threads a process: the case needs more than 1,024 live'
		r := os.execute('N=${n} GCS=3 WATCHDOG_S=120 ${os.quoted_path(exe)}')
		assert r.exit_code == 0, 'N=${n}: exit ${r.exit_code}: ${r.output}'
		assert r.output.contains('ok=true'), 'N=${n}: ${r.output}'
		wall := r.output.all_after('wall_ms=').all_before(' ').int()
		assert wall < 60000, 'N=${n}: ${wall} ms wall (bounded: 60 s)'
		println('N=${n}: ${r.output.trim_space()}')
	}
}
