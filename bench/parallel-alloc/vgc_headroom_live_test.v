// vgc_headroom_live_test.v — the adaptive headroom is bounded by the live set
// (cx-home/v#12, the cx side of cx-private#1892).
//
// Shape: a 24 MB live set of 48-byte linked nodes (a pointer-rich tree, as a
// parsed document is) is built and held, then sixteen times its size streams
// past in 4 KB transients; the child reports the carved high-water
// (gc_memory_use()) over the live bytes. Marking half a million nodes costs
// more than a tenth of the interval between cycles, so the pacer's time band
// doubles the headroom to the flat 64 MB cap and the goal sits at marked +
// 64 MB — over 3.5× a live set that never grows (json-codec 1 MB on dev2:
// 153 MB peak for 20 MB marked, Python 42 MB). With the live-set bound
// (VGC_HEADROOM_LIVE_PCT, 100 by default) the headroom is at most the marked
// set, so the goal is 2× the live set, Go's GOGC=100 goal. The default must
// carve less than the bound off (VGC_HEADROOM_LIVE_PCT=0) and stay under 2.5×
// (cx-private 1226-a).
//
// Run: ./v test bench/parallel-alloc/vgc_headroom_live_test.v
module main

import os

struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

const chunk = 4096
const live_bytes = 24 * 1024 * 1024
const node_bytes = 48
const churn_rounds = 16

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
	mut high := gc_memory_use()
	mut sink := u64(0)
	for i in 0 .. churn_rounds * live_bytes / chunk {
		t := []u8{len: chunk, init: u8(i)}
		sink += t[i % chunk]
		if i % 64 == 0 {
			c := gc_memory_use()
			if c > high {
				high = c
			}
		}
	}
	mut kept := 0
	for n := head; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('RATIO=${f64(high) / f64(live_bytes):.3f} sink=${sink} kept=${kept}')
}

fn ratio(pct string) f64 {
	env := if pct == '' { '' } else { 'VGC_HEADROOM_LIVE_PCT=${pct} ' }
	r := os.execute('VGC_LIVE_CHILD=1 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	for l in r.output.split_into_lines() {
		if l.starts_with('RATIO=') {
			return l.all_after('RATIO=').all_before(' ').f64()
		}
	}
	panic(r.output)
}

fn test_the_headroom_is_bounded_by_the_live_set() {
	if os.getenv('VGC_LIVE_CHILD') != '' {
		child()
		return
	}
	on := ratio('')
	off := ratio('0')
	println('vgc_headroom_live: bound default ${on:.3f}x, bound off ${off:.3f}x (carved high / live)')
	assert on < off, 'the live-set bound does not lower the carve: ${on:.3f}x against bound off ${off:.3f}x'
	assert on <= 2.5, 'the bounded pacer carved ${on:.3f}x the live set (bar 2.5x)'
}
