// vgc_headroom_live_test.v — the adaptive headroom is bounded by the live set
// (cx-home/v#12, the cx side of cx-private#1892).
//
// Shape: a 40 MB live set of 48-byte linked nodes (a pointer-rich tree, as a
// parsed document is) is built and held, then twelve times its size streams
// past in 4 KB transients; the child reports the carved high-water
// (gc_memory_use()) over the live bytes. Marking most of a million nodes costs
// more than a tenth of the interval between cycles, so the pacer's time band
// doubles the headroom to the flat 64 MB cap and the goal sits at marked +
// 64 MB — 2.6× a live set that never grows (json-codec 1 MB on dev2: 153 MB
// peak for 20 MB marked, Python 42 MB). With the live-set bound
// (VGC_HEADROOM_LIVE_PCT, 100 by default) the headroom is at most the marked
// set, so the goal is 2× the live set, Go's GOGC=100 goal. The default must
// carve less than the bound off (VGC_HEADROOM_LIVE_PCT=0) and stay under 2.3×
// (cx-private 1226-a). The live set is above the bound's 32 MB floor
// (vgc_headroom_live_floor) so the bound itself is what the ratio measures; the
// second case holds an 8 MB set under the same churn and shows the floor: the
// default carve is the floor's (32 MB over 8 live), a 16 MB floor carves less.
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
const live_bytes = 40 * 1024 * 1024
const small_live_bytes = 8 * 1024 * 1024
const node_bytes = 48
const churn_rounds = 12

fn child(live_bytes int) {
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

fn ratio(env string, live string) f64 {
	r := os.execute('VGC_LIVE_CHILD=${live} ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	for l in r.output.split_into_lines() {
		if l.starts_with('RATIO=') {
			return l.all_after('RATIO=').all_before(' ').f64()
		}
	}
	panic(r.output)
}

fn test_the_headroom_is_bounded_by_the_live_set() {
	which := os.getenv('VGC_LIVE_CHILD')
	if which == 'big' {
		child(live_bytes)
		return
	}
	if which == 'small' {
		child(small_live_bytes)
		return
	}
	on := ratio('', 'big')
	off := ratio('VGC_HEADROOM_LIVE_PCT=0 ', 'big')
	println('vgc_headroom_live: bound default ${on:.3f}x, bound off ${off:.3f}x (carved high / live, 40 MB live)')
	// The bound binds only when the unbounded pacer carves past it: the time
	// band doubles the headroom when marking costs more than a tenth of the
	// interval, which a fast runner's mark may not (GitHub's ubuntu-24.04 runner:
	// 1.6x bound off, 1.6x on — the headroom never left its floor). So the bound
	// must never carve MORE, and must carve less wherever bound-off went past
	// 2x + the floor's margin; the 2.3x bar holds on every box.
	assert on <= off + 0.05, 'the live-set bound raised the carve: ${on:.3f}x against bound off ${off:.3f}x'
	if off > 2.3 {
		assert on < off, 'the live-set bound does not lower the carve: ${on:.3f}x against bound off ${off:.3f}x'
	}
	assert on <= 2.3, 'the bounded pacer carved ${on:.3f}x the live set (bar 2.3x)'
}

fn test_the_bound_has_a_floor() {
	if os.getenv('VGC_LIVE_CHILD') != '' {
		return
	}
	floor32 := ratio('', 'small')
	floor16 := ratio('VGC_HEADROOM_LIVE_FLOOR_MB=16 ', 'small')
	println('vgc_headroom_live: 8 MB live — default floor ${floor32:.3f}x, 16 MB floor ${floor16:.3f}x')
	// 8 MB live under the 32 MB floor: the carve is live + floor (+ slack), 5x,
	// not the 2x the bare bound would force; a 16 MB floor carves measurably less.
	assert floor32 >= 4.0, 'the default floor did not hold: ${floor32:.3f}x (expected live + 32 MB, ~5x)'
	assert floor16 < floor32, 'a 16 MB floor carved ${floor16:.3f}x, not less than the default ${floor32:.3f}x'
}
