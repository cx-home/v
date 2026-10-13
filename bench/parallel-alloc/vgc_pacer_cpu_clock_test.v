// vgc_pacer_cpu_clock_test.v — the pacer judges a collection's cost by the
// collector's CPU time, not its wall time (cx-home/v#42, cx-private#1927).
//
// On a busy box the collector waits for a core: the stop, the pool's wakes and
// its own slices. cx-private#1836 read a 4.5 ms pause as 65-70 ms with no
// extra work, and the pacer's time band (grow the headroom when the cycle costs
// over a tenth of the mutator interval) bought headroom — RSS — for load the
// program did not make; the gates' rate bound read the same clock and stood
// down. The contention is injected deterministically: VGC_TEST_COLLECTOR_STALL_US
// makes the collector sleep inside each cycle, off its core, as a descheduled
// collector is. The child holds a 1 MB live set and churns 4 KB transients
// with ~20 us of arithmetic each (a mutator interval of milliseconds per cycle,
// a pause well under a tenth of it), and reports the headroom of its last
// collections from the VGC_GCTRACE=1 lines. The live-set bound is off
// (VGC_HEADROOM_LIVE_PCT=0): one allocating thread's headroom is otherwise
// pinned to its marked set whatever the band says, and the band is what the
// clock feeds (dev2: quiet 8 MB, stalled 8 MB, stalled on the wall clock
// 16 -> 32 -> 64 MB in three cycles). Bar (cx-private#1927): the verdict
// under the stall equals the quiet one. The same stall under VGC_PACER_WALL=1
// (the wall-time pacer every build before v#42 ran) must move it — the proof
// the stall is contention the old clock reads.
//
// Run: ./v test bench/parallel-alloc/vgc_pacer_cpu_clock_test.v
module main

import os
import time

struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

const live_bytes = 1024 * 1024
const node_bytes = 48
const chunk = 4096
const churn_bytes = 256 * 1024 * 1024

fn child() {
	mut head := &Node(unsafe { nil })
	for i in 0 .. live_bytes / node_bytes {
		mut n := &Node{
			next: head
		}
		n.pad[0] = u64(i)
		head = n
	}
	mut sink := u64(0)
	for i in 0 .. churn_bytes / chunk {
		t := []u8{len: chunk, init: u8(i)}
		mut x := u64(t[i % chunk]) | 1
		for _ in 0 .. 20000 {
			x = x * 6364136223846793005 + 1442695040888963407
		}
		sink += x & 1
	}
	mut kept := 0
	for n := head; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('DONE sink=${sink} kept=${kept}')
}

// the headroom (KB) of the last quarter of the run's collections, at most
fn headroom_kb(env string) (u64, int, i64) {
	sw := time.new_stopwatch()
	r := os.execute('VGC_PACER_CHILD=1 VGC_GCTRACE=1 VGC_HEADROOM_LIVE_PCT=0 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	dpath := '/tmp/pacer_diag_${os.getpid()}_${time.now().unix_micro()}.txt'
	os.write_file(dpath, 'ENV=${env} MPM=${os.getenv('VGC_MARK_PAR_MIN_US')}\n' + r.output) or {}
	mut hs := []u64{}
	for l in r.output.split_into_lines() {
		if l.starts_with('[gc ') && l.contains(' headroom=') {
			hs << l.all_after(' headroom=').all_before('KB').u64()
		}
	}
	assert hs.len >= 4, 'too few collections (${hs.len}) to read a verdict: ${r.output#[-400..]}'
	mut m := u64(0)
	for h in hs#[hs.len - (hs.len + 3) / 4..] {
		if h > m {
			m = h
		}
	}
	return m, hs.len, sw.elapsed().microseconds()
}

fn test_a_descheduled_collector_does_not_grow_the_headroom() {
	if os.getenv('VGC_PACER_CHILD') != '' {
		child()
		return
	}
	$if windows {
		// no per-thread CPU clock fine enough: the pacer keeps the wall clock there
		return
	}
	quiet, nq, us := headroom_kb('')
	// the stall is one quiet mutator interval (at least 40 ms, at most 1 s): the
	// wall-time band grows the headroom while the stall exceeds a tenth of the
	// interval, so a stall sized to the host keeps the control at >= 4x on a slow
	// or shared runner too (FreeBSD CI at 4 jobs: a fixed 40 ms was under a tenth
	// of its interval after one doubling — 16 MB against quiet 8 MB)
	mut stall := us / i64(nq)
	if stall < 40000 {
		stall = 40000
	}
	if stall > 1000000 {
		stall = 1000000
	}
	stalled, ns, _ := headroom_kb('VGC_TEST_COLLECTOR_STALL_US=${stall} ')
	wall, nw, _ := headroom_kb('VGC_TEST_COLLECTOR_STALL_US=${stall} VGC_PACER_WALL=1 ')
	println('vgc_pacer_cpu_clock: headroom of the last collections — quiet ${quiet} KB (${nq} cycles, ${us / 1000} ms), ${stall / 1000} ms stall per cycle ${stalled} KB (${ns}), the same stall on the wall-time pacer ${wall} KB (${nw})')
	// the old clock reads the stall as cost: the band doubles the headroom
	assert wall >= quiet * 4, 'the stall did not move the wall-time pacer (${wall} KB against quiet ${quiet} KB): the injection is not contention'
	// the CPU clock does not: the same verdict as the quiet run (one doubling of slack)
	assert stalled <= quiet * 2, 'a descheduled collector grew the headroom: ${stalled} KB against quiet ${quiet} KB (wall-time pacer: ${wall} KB)'
}
