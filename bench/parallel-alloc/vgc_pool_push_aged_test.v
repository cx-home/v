// cx-home/v#11: vgc_pool_push_aged files a span by age on its hot chain. It
// walked the chain from the tail on every push (O(n) per push, a struct compare
// per step: 45 % of pi-digits' CPU). This drives the white-box self-check in
// module builtin (vgc_pool_aged_selftest): the chain stays in the order the
// trim needs, and ten times the pushes cost about ten times the time, not a
// hundred (the tail walk: 3k -> 30k pushes took 42 ms -> 6.76 s, 161x).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pool_push_aged_test.v
module main

fn least_ns(n int) u64 {
	mut best := u64(0)
	for i in 0 .. 3 {
		rc, ns := vgc_pool_aged_selftest(n)
		assert rc == 0, 'chain order check ${rc} at n=${n}'
		if i == 0 || ns < best {
			best = ns
		}
	}
	return best
}

fn test_aged_pushes_keep_trim_order() {
	for n in [1, 2, 3, 7, 100, 1000] {
		rc, _ := vgc_pool_aged_selftest(n)
		assert rc == 0, 'chain order check ${rc} at n=${n}'
	}
}

fn test_aged_pushes_cost_linear_time() {
	small := least_ns(10_000)
	large := least_ns(100_000)
	ratio := f64(large) / f64(if small == 0 { u64(1) } else { small })
	eprintln('vgc_pool_push_aged: 10k ${small} ns, 100k ${large} ns, ratio ${ratio:.1f}')
	assert ratio < 30.0
}
