// churn.v — the fixture of vgc_pace_recheck_test.v (cx-core-code#133): THREADS workers each
// allocate small arrays and keep the last RING of them (a small live set, ~2 MB in all), so
// every worker crosses the trigger within a few microseconds of the others and the collections
// run back to back with the workers all allocating. It prints the collections it saw complete
// (gc_cycles()) and `done`.
module main

import os

fn work(rounds int, seed int, out chan u64) {
	mut ring := [][]int{len: 512}
	mut sink := u64(0)
	for i := 0; i < rounds; i++ {
		t := []int{len: 64, init: index + i + seed}
		ring[i % ring.len] = t
		sink += u64(t[i % 64])
	}
	out <- sink
}

fn main() {
	threads := if os.args.len > 1 { os.args[1].int() } else { 8 }
	rounds := if os.args.len > 2 { os.args[2].int() } else { 400000 }
	out := chan u64{cap: threads}
	for k in 0 .. threads {
		spawn work(rounds, k, out)
	}
	mut sum := u64(0)
	for _ in 0 .. threads {
		sum += <-out
	}
	println('cycles ${gc_cycles()} sum ${sum}')
	println('done')
}
