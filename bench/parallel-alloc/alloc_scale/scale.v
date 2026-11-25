// scale.v — vgc_alloc_scale_test's fixture (cx-private#2040): the same small
// allocations on 1 thread, then on THREADS threads at once, in one process.
// Each phase prints the process's CPU cycles and instructions per allocation
// (proc_pid_rusage; the collector's threads included). Every object is dead
// at once (the live set is one sink word a thread), so the phases differ only
// in how many threads allocate together.
//
//   THREADS=16 ALLOCS=2000000 ROUNDS=3 ./scale
module main

import os

#include "@DIR/cycles.h"

fn C.vgc_as_cycles() u64
fn C.vgc_as_instructions() u64

struct Small {
	a u64
	b u64
	n &Small = unsafe { nil }
}

fn worker(n int, seed u64) u64 {
	mut acc := u64(seed)
	mut prev := &Small(unsafe { nil })
	for i in 0 .. n {
		mut s := &Small{
			a: acc
			b: u64(i)
			n: prev
		}
		acc += s.a ^ s.b
		// keep one object reachable from the next, then drop the chain
		prev = if i & 7 == 0 { &Small(unsafe { nil }) } else { s }
	}
	return acc
}

fn phase(threads int, n int) (f64, f64, u64) {
	c0 := C.vgc_as_cycles()
	i0 := C.vgc_as_instructions()
	mut acc := u64(0)
	if threads == 1 {
		acc = worker(n, 1)
	} else {
		mut hs := []thread u64{cap: threads}
		for t in 0 .. threads {
			hs << spawn worker(n, u64(t))
		}
		for h in hs {
			acc += h.wait()
		}
	}
	c1 := C.vgc_as_cycles()
	i1 := C.vgc_as_instructions()
	allocs := f64(threads) * f64(n)
	return f64(c1 - c0) / allocs, f64(i1 - i0) / allocs, acc
}

fn main() {
	threads := os.getenv_opt('THREADS') or { '16' }.int()
	n := os.getenv_opt('ALLOCS') or { '2000000' }.int()
	rounds := os.getenv_opt('ROUNDS') or { '3' }.int()
	// warm both shapes once (the heap's first spans, the threads' slots)
	phase(1, n / 4)
	phase(threads, n / 4)
	for r in 0 .. rounds {
		c1, i1, a1 := phase(1, n)
		ck, ik, ak := phase(threads, n)
		println('round ${r} t1 cyc/alloc=${c1:.2f} ins/alloc=${i1:.2f} t${threads} cyc/alloc=${ck:.2f} ins/alloc=${ik:.2f} ratio=${ck / c1:.3f} acc=${a1 ^ ak}')
	}
}
