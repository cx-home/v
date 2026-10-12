// born.v — the fixture of vgc_cm_born_test.v (cx-private#1910 cut 1): a live
// set of LIVE_MB of pointer-bearing 64-byte records (a slow mark) held by main
// while THREADS workers allocate 1 KB records into rolling windows as fast as
// they can for the run's length, so a concurrent cycle's middle sees births of
// many times the live set. Prints `cycles=N` at the end; the test reads the
// VGC_GCTRACE=2 lines beside it.
module main

import os
import time

@[heap]
struct Node {
mut:
	a    u64
	next &Node = unsafe { nil }
	b    u64
	c    u64
	d    u64
	e    u64
	f    u64
	g    u64
}

@[heap]
struct Rec {
mut:
	id   u64
	next &Rec = unsafe { nil }
	pad  [124]u64
}

// a thread's churn: every record points at the shared anchor (a heap object,
// so the record is a scan object the barrier and the re-scan see), never at an
// older record — the window's drops are garbage
fn churn(id u64, ops u64, anchor &Rec) u64 {
	mut ring := []&Rec{len: 64, init: unsafe { nil }}
	mut sum := u64(0)
	for i in u64(0) .. ops {
		r := &Rec{
			id:   i + id
			next: anchor
		}
		ring[int(i % 64)] = r
		sum += r.id
	}
	return sum
}

fn main() {
	live_mb := os.getenv_opt('LIVE_MB') or { '48' }.int()
	threads := os.getenv_opt('THREADS') or { '8' }.int()
	ops := u64(os.getenv_opt('OPS') or { '400000' }.int())
	// the live set: live_mb of 64-byte nodes in one chain
	n := live_mb * 1024 * 1024 / 64
	mut head := &Node(unsafe { nil })
	for i in 0 .. n {
		head = &Node{
			a:    u64(i)
			next: head
		}
	}
	anchor := &Rec{
		id: 1
	}
	t0 := time.now()
	mut ths := []thread u64{}
	for t in 0 .. threads {
		ths << spawn churn(u64(t), ops, anchor)
	}
	mut sum := u64(0)
	for th in ths {
		sum += th.wait()
	}
	// the chain is still live here
	mut cnt := 0
	mut p := head
	for p != unsafe { nil } {
		cnt++
		p = p.next
	}
	println('cycles=${gc_cycles()} live_nodes=${cnt} sum=${sum} anchor=${anchor.id} ms=${time.since(t0).milliseconds()}')
}
