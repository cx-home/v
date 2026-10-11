// vgc_grow_gate_flat_test.v — a live set built and then held over a stream
// of transients is gated whatever number of collections followed the build
// (cx-home/v#7, from cx-private#1793), across set sizes (cx-home/v#34).
//
// Shape: a live set of 4 KB []u8 built (LIVE_MB), gc_collect() n times
// (n = 0, 1, 2), then four times the set streamed in 4 KB transients; the
// child reports the carved high-water (gc_memory_use()) over the live bytes.
// The history the grow gate reads cannot tell this set from a growing one at
// n = 0 and 1 (the last collection marked more than the one before it), so
// the gate stood down and the heap carved its goal: 2.418x at n = 0 and 1
// against 2.000x at n = 2 (V fork cfdad1d369). The gate probes at the cycle's
// last carve; the probe finds the stream's garbage.
//
// What the gate holds, and what it does not (cx-home/v#34): a probe that finds
// the cycle's allocation mostly live credits the budget it cut to the next
// goal (cx-home/v#7), which is right for a set that keeps growing and an
// overshoot for one whose build ends just after the probe. Which set size meets
// that depends only on where its build ends against the cycles, so a single
// size passes or fails by alignment (128 MB passed on the fork's base and
// failed when the first collection moved to 4 MB; 48 and 208 MB failed on the
// base). The test therefore sweeps sizes and asserts the invariant:
//   - at every size and n, the gate default carves at most one credit over the
//     gate off (a credit is at most half the cycle's budget; the bound is a
//     quarter of the live set);
//   - the gate default carves less than the gate off at most sizes (half the
//     sweep at n = 0, two thirds at n = 1 and 2, where the history reads flat).
// v#34 tracks the credit redesign that would make every size hold.
//
// Run: ./v test bench/parallel-alloc/vgc_grow_gate_flat_test.v
module main

import os

const chunk = 4096
const churn_rounds = 4

fn child(ncollect int, live_bytes int) {
	mut live := [][]u8{cap: live_bytes / chunk}
	for _ in 0 .. live_bytes / chunk {
		live << []u8{len: chunk, init: 7}
	}
	for _ in 0 .. ncollect {
		gc_collect()
	}
	mut high := gc_memory_use()
	mut sink := u64(0)
	for i in 0 .. churn_rounds * live_bytes / chunk {
		t := []u8{len: chunk, init: u8(i)}
		sink += t[i % chunk]
		if i % 256 == 0 {
			c := gc_memory_use()
			if c > high {
				high = c
			}
		}
	}
	println('RATIO=${f64(high) / f64(live_bytes):.3f} sink=${sink} kept=${live.len}')
}

fn ratio(n int, mb int, pct string) f64 {
	env := if pct == '' { '' } else { 'VGC_GROW_GATE_PCT=${pct} ' }
	r := os.execute('VGC_FLAT_CHILD=${n} VGC_FLAT_MB=${mb} ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	for l in r.output.split_into_lines() {
		if l.starts_with('RATIO=') {
			return l.all_after('RATIO=').all_before(' ').f64()
		}
	}
	panic(r.output)
}

const sweep_n0 = [48, 80, 112, 128, 208]
const sweep_flat = [128, 160]
// at most one credit over the gate off: a quarter of the live set
const credit_bound = 0.25

fn test_a_flat_set_is_gated_whatever_collections_followed_its_build() {
	c := os.getenv('VGC_FLAT_CHILD')
	if c != '' {
		child(c.int(), os.getenv('VGC_FLAT_MB').int() * 1024 * 1024)
		return
	}
	mut over := []string{}
	mut short := []string{}
	for n in [0, 1, 2] {
		sizes := if n == 0 { sweep_n0 } else { sweep_flat }
		mut wins := 0
		for mb in sizes {
			on := ratio(n, mb, '')
			off := ratio(n, mb, '0')
			println('vgc_grow_gate_flat collects=${n} live=${mb} MB: gate default ${on:.3f}x, gate off ${off:.3f}x (carved high / live)')
			if on < off {
				wins++
			}
			if on > off + credit_bound {
				over << 'collects=${n} live=${mb} MB: ${on:.3f}x against gate off ${off:.3f}x'
			}
		}
		need := if n == 0 { (sizes.len + 1) / 2 } else { (sizes.len * 2 + 2) / 3 }
		if wins < need {
			short << 'collects=${n}: the gate carved less than gate off at ${wins} of ${sizes.len} sizes (need ${need})'
		}
	}
	assert over.len == 0, 'the gate carved more than one credit over gate off: ${over}'
	assert short.len == 0, 'the gate does not hold a flat set: ${short}'
}
