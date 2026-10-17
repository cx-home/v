// cx-home/v#11: vgc_pool_push_aged files a span by age on its hot chain. It
// walked the chain from the tail on every push (O(n) per push, a struct compare
// per step: 45 % of pi-digits' CPU). This drives the white-box self-check in
// module builtin (vgc_pool_aged_selftest): the chain stays in the order the
// trim needs, and ten times the pushes cost about ten times the time, not a
// hundred (the tail walk: 3k -> 30k pushes took 42 ms -> 6.76 s, 161x).
//
// The judge is the walk's step count (cx-home/v#54), not wall time: the 10k
// arm took ~0.25 ms, and a 4-vCPU Linux runner at load 3.1 read the 100k arm
// at 35.3x it (CI 39035141118), past the 30x bound #38 kept for runners that
// are not oversubscribed — the 100k arm's 20 MB of descriptors leave the
// caches the 10k arm runs in, so even an O(1) push reads more than 10x, and a
// load average cannot tell a busy core from a cold cache. vgc_pool_push_aged
// counts each step of its two-ended walk (vgc_pool_aged_selftest_steps); a
// per-push walk takes steps in proportion to the chain (the tail walk: ~n*n/8
// for n pushes), the filing this test guards takes at most one per push. The
// times are printed, not judged.
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pool_push_aged_test.v
module main

import runtime

fn C.getloadavg(loadavg &f64, nelem int) int

// load1 is the one-minute load average, or -1 where getloadavg answers nothing
// (and on Windows, which has none).
fn load1() f64 {
	$if windows {
		return -1
	} $else {
		mut la := [3]f64{}
		if C.getloadavg(&la[0], 1) != 1 {
			return -1
		}
		return la[0]
	}
}

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
	small_steps := vgc_pool_aged_selftest_steps()
	large := least_ns(100_000)
	large_steps := vgc_pool_aged_selftest_steps()
	ratio := f64(large) / f64(if small == 0 { u64(1) } else { small })
	eprintln('vgc_pool_push_aged: 10k ${small} ns ${small_steps} steps, 100k ${large} ns ${large_steps} steps, time ratio ${ratio:.1f} (load ${load1():.1f} on ${runtime.nr_cpus()} CPUs)')
	assert small_steps <= 10_000, '10k aged pushes walked ${small_steps} chain steps: the per-push walk is back'
	assert large_steps <= 100_000, '100k aged pushes walked ${large_steps} chain steps: the per-push walk is back'
}
