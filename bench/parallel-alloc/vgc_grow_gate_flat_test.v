// vgc_grow_gate_flat_test.v — a live set built and then held over a stream
// of transients is gated whatever number of collections followed the build
// (cx-home/v#7, from cx-private#1793).
//
// Shape: 128 MB of 4 KB []u8 built, gc_collect() n times (n = 0, 1, 2), then
// four times the set streamed in 4 KB transients; the child reports the
// carved high-water (gc_memory_use()) over the live bytes. The history the
// grow gate reads cannot tell this set from a growing one at n = 0 and 1 (the
// last collection marked more than the one before it), so the gate stood down
// and the heap carved its goal: 2.418x at n = 0 and 1 against 2.000x at n = 2
// (V fork cfdad1d369). The gate now probes at the cycle's last carve; the
// probe finds the stream's garbage. The gate at its default must carve less
// than the gate off (VGC_GROW_GATE_PCT=0) at every n.
//
// Run: ./v test bench/parallel-alloc/vgc_grow_gate_flat_test.v
module main

import os

const chunk = 4096
const live_bytes = 128 * 1024 * 1024
const churn_rounds = 4

fn child(ncollect int) {
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

fn ratio(n int, pct string) f64 {
	env := if pct == '' { '' } else { 'VGC_GROW_GATE_PCT=${pct} ' }
	r := os.execute('VGC_FLAT_CHILD=${n} ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	for l in r.output.split_into_lines() {
		if l.starts_with('RATIO=') {
			return l.all_after('RATIO=').all_before(' ').f64()
		}
	}
	panic(r.output)
}

fn test_a_flat_set_is_gated_whatever_collections_followed_its_build() {
	c := os.getenv('VGC_FLAT_CHILD')
	if c != '' {
		child(c.int())
		return
	}
	mut bad := []string{}
	for n in [0, 1, 2] {
		on := ratio(n, '')
		off := ratio(n, '0')
		println('vgc_grow_gate_flat collects=${n}: gate default ${on:.3f}x, gate off ${off:.3f}x (carved high / live)')
		if on >= off {
			bad << 'collects=${n}: ${on:.3f}x against gate off ${off:.3f}x'
		}
	}
	assert bad.len == 0, 'the gate does not hold a flat set: ${bad}'
}
