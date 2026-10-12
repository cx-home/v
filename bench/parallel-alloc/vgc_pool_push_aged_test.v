// cx-home/v#11: vgc_pool_push_aged files a span by age on its hot chain. It
// walked the chain from the tail on every push (O(n) per push, a struct compare
// per step: 45 % of pi-digits' CPU). This drives the white-box self-check in
// module builtin (vgc_pool_aged_selftest): the chain stays in the order the
// trim needs, and ten times the pushes cost about ten times the time, not a
// hundred (the tail walk: 3k -> 30k pushes took 42 ms -> 6.76 s, 161x).
//
// The ratio is wall time (cx-home/v#38): on FreeBSD's 4-vCPU CI runner with
// four test binaries in parallel the 100k arm read 30.2x the 10k one (vgc
// 38301540287) where an idle box reads 11-14x. A run judges < 60x always —
// still far under the quadratic walk's 161x — and the tight < 30x only when
// the runner is not oversubscribed (one-minute load at the start and end at
// most the CPU count; Windows, which has no getloadavg, judges as before).
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
	load_start := load1()
	small := least_ns(10_000)
	large := least_ns(100_000)
	load_end := load1()
	ratio := f64(large) / f64(if small == 0 { u64(1) } else { small })
	ncpu := f64(runtime.nr_cpus())
	eprintln('vgc_pool_push_aged: 10k ${small} ns, 100k ${large} ns, ratio ${ratio:.1f} (load ${load_start:.1f} -> ${load_end:.1f} on ${ncpu} CPUs)')
	assert ratio < 60.0, 'ten times the aged pushes cost ${ratio:.1f}x the time: the per-push walk is back'
	if load_start > ncpu || load_end > ncpu {
		eprintln('vgc_pool_push_aged: the tight 30x bound not judged on an oversubscribed runner')
		return
	}
	assert ratio < 30.0, 'ten times the aged pushes cost ${ratio:.1f}x the time (load ${load_start:.1f} -> ${load_end:.1f} on ${ncpu} CPUs)'
}
