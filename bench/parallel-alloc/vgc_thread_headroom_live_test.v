// vgc_thread_headroom_live_test.v — many allocating threads over a small live
// set keep a heap the size of the live set, not of the thread count
// (https://github.com/cx-home/cx-core-code/issues/297: cx fannkuch-redux 12
// [par 28] keeps ~3 MB marked and peaked at 310 MB, Python's largest pool
// process 19.8 MB).
//
// The pacer's several-threads floor is clamp(2 x marked, 4 MB, 32 MB) times
// the threads that allocated (cx-home/v#16): 6 MB x 28 = 168 MB of headroom
// over a 3 MB live set. It is capped at 4 x marked only while the band reads
// the collections as cheap (cx-private#1910), and a stop that holds 28
// mutators never reads cheap, so the goal rides at ~170-195 MB and the swept
// pool stays resident in the threads' arenas.
//
// Shape: a 3 MB live set (48-byte linked nodes, held for the whole run) is
// built on the main thread; then `threads` workers (28, the [par 28] of the
// card cell, capped at the box's cpus) each allocate short-lived 12-element
// arrays — a permutation copied per step, as the card's program does — for
// churn_mb_per_thread MB each. The child prints its resident-set high-water
// (getrusage ru_maxrss) over the resident set before the workers start, so the
// binary's text, the libraries and the main thread's state are not counted.
// Bar: the growth is at most the live set times (1 + 8) — the live set and a
// headroom of eight times it (vgc_headroom_thread_live_x) — plus 1.5 MB a
// worker (its in-flight spans, its stash of free spans, its share of a stop's
// overshoot). The head grows by ~7 MB a worker (a 6 MB floor each): 127.9 MB
// at 18 workers (pbm1), where the bar is 54 MB.
//
// Run: ./v test bench/parallel-alloc/vgc_thread_headroom_live_test.v
module main

import os
import runtime
import time

#include <sys/resource.h>

struct C.rusage {
	ru_maxrss i64
}

fn C.getrusage(who int, usage &C.rusage) int

struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

const live_bytes = 3 * 1024 * 1024
const node_bytes = 48
const max_threads = 28
const churn_mb_per_thread = 96
// the bound on the resident growth: live x (1 + headroom_x) + per_thread_mb a worker (the header)
const headroom_x = 8
const per_thread_mb = 1.5

fn maxrss_bytes() i64 {
	mut ru := C.rusage{}
	C.getrusage(0, &ru)
	$if macos {
		return ru.ru_maxrss
	}
	return ru.ru_maxrss * 1024
}

fn worker(id int, bytes i64) u64 {
	mut perm := []int{len: 12, init: index}
	mut acc := u64(id)
	steps := bytes / 96 // a 12-int array's 96-byte payload carved a step
	for i in i64(0) .. steps {
		mut next := perm.clone()
		k := int(i % 11) + 1
		t := next[0]
		next[0] = next[k]
		next[k] = t
		acc += u64(next[0] ^ next[11])
		perm = unsafe { next }
	}
	return acc
}

fn child() {
	mut head := &Node(unsafe { nil })
	for i in 0 .. live_bytes / node_bytes {
		mut n := &Node{
			next: head
		}
		n.pad[0] = u64(i)
		head = n
	}
	gc_collect()
	base := maxrss_bytes()
	mut threads := runtime.nr_cpus()
	if threads > max_threads {
		threads = max_threads
	}
	t0 := time.now()
	mut hs := []thread u64{cap: threads}
	for t in 0 .. threads {
		hs << spawn worker(t, i64(churn_mb_per_thread) * 1024 * 1024)
	}
	mut acc := u64(0)
	for h in hs {
		acc += h.wait()
	}
	wall := time.since(t0)
	peak := maxrss_bytes()
	mut kept := 0
	for n := head; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('GROWTH_MB=${f64(peak - base) / 1048576.0:.1f} base_mb=${f64(base) / 1048576.0:.1f} threads=${threads} wall_ms=${wall.milliseconds()} kept=${kept} acc=${acc}')
}

fn test_many_threads_over_a_small_live_set_keep_a_live_sized_heap() {
	if os.getenv('VGC_THL_CHILD') == '1' {
		child()
		return
	}
	r := os.execute('VGC_THL_CHILD=1 ${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	mut line := ''
	for l in r.output.split_into_lines() {
		if l.starts_with('GROWTH_MB=') {
			line = l
		}
	}
	assert line != '', r.output
	growth := line.all_after('GROWTH_MB=').all_before(' ').f64()
	threads := line.all_after('threads=').all_before(' ').int()
	live_mb := f64(live_bytes) / 1048576.0
	bound := live_mb * f64(1 + headroom_x) + per_thread_mb * f64(threads)
	println('vgc_thread_headroom_live: ${line} (bar: growth <= ${bound:.1f} MB = ${live_mb:.0f} MB live x ${1 + headroom_x} + ${per_thread_mb} MB x ${threads} workers)')
	assert growth <= bound, 'the resident set grew ${growth:.1f} MB over a ${live_mb:.0f} MB live set with ${threads} allocating threads (bar ${bound:.1f} MB)'
}
