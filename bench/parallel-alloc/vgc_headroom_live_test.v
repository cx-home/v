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
const tiny_live_bytes = 2 * 1024 * 1024
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
	// at least 96 MB of churn, so a tiny live set still runs enough cycles for
	// the time band to ride its headroom up to the floor (8 and 40 MB: unchanged)
	mut churn := churn_rounds * live_bytes
	if churn < 96 * 1024 * 1024 {
		churn = 96 * 1024 * 1024
	}
	for i in 0 .. churn / chunk {
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
	if which == 'start' {
		start_child()
		return
	}
	if which != '' {
		return
	}
	// The bound binds only when the unbounded pacer carves past it, and left to
	// itself the time band is the runner's: since cx-home/v#42 it reads the
	// collector's work CPU, so one run of a pair can ride the band to the 64 MB
	// cap while the other keeps its base (Linux CI, the same build: bound default
	// 1.600x / bound off 2.626x, then 2.026x / 2.626x, then 2.026x / 1.600x — a
	// comparison of two band draws, not of the bound). The band is held up here
	// as in test_the_bound_has_a_floor (the wall-time pacer and a 50 ms collector
	// stall per cycle), so bound off carves marked + the 64 MB cap (~2.6x) on
	// every runner and the pair reads the bound alone.
	band := 'VGC_PACER_WALL=1 VGC_TEST_COLLECTOR_STALL_US=50000 '
	on := ratio(band, 'big')
	off := ratio(band + 'VGC_HEADROOM_LIVE_PCT=0 ', 'big')
	println('vgc_headroom_live: band held up — bound default ${on:.3f}x, bound off ${off:.3f}x (carved high / live, 40 MB live)')
	assert off > 2.3, 'the band held up did not carve past the bound with the bound off: ${off:.3f}x (expected marked + 64 MB, ~2.6x)'
	assert on < off, 'the live-set bound does not lower the carve: ${on:.3f}x against bound off ${off:.3f}x'
	assert on <= 2.3, 'the bounded pacer carved ${on:.3f}x the live set (bar 2.3x)'
}

fn test_the_bound_has_a_floor() {
	if os.getenv('VGC_LIVE_CHILD') != '' {
		return
	}
	// The band is held up (the wall-time pacer and a 50 ms collector stall per
	// cycle, the shape vgc_pacer_cpu_clock_test injects): the floor is what this
	// test reads, and it shows only where the band asks for more than it. Left
	// to itself the band is the runner's (cx-home/v#42: it reads the
	// collector's work CPU, so a runner where marking 8 MB is cheap keeps it at
	// its base — Linux CI's walks-forced mode carved 2.07x with the fixed floor,
	// then 3.8x against 5.1x bound off on the next run).
	band := 'VGC_PACER_WALL=1 VGC_TEST_COLLECTOR_STALL_US=50000 '
	fixed32 := ratio(band + 'VGC_HEADROOM_ADAPTIVE_FLOOR=0 ', 'small')
	fixed16 := ratio(band + 'VGC_HEADROOM_ADAPTIVE_FLOOR=0 VGC_HEADROOM_LIVE_FLOOR_MB=16 ', 'small')
	adaptive := ratio(band, 'small')
	println('vgc_headroom_live: 8 MB live, band held up — fixed 32 MB floor ${fixed32:.3f}x, fixed 16 MB floor ${fixed16:.3f}x, adaptive floor ${adaptive:.3f}x')
	// 8 MB live under the fixed 32 MB floor: the carve is live + floor (+ slack), 5x,
	// not the 2x the bare bound would force; a 16 MB floor carves measurably less.
	assert fixed32 >= 4.0, 'the fixed floor did not hold: ${fixed32:.3f}x (expected live + 32 MB, ~5x)'
	assert fixed16 < fixed32, 'a 16 MB floor carved ${fixed16:.3f}x, not less than the fixed 32 MB floor ${fixed32:.3f}x'
	// The adaptive floor (cx-home/v#14) is clamp(2 x marked, 4 MB, 32 MB): 16 MB
	// over 8 MB live, so the carve is ~3x, below the fixed floor's.
	assert adaptive < fixed32, 'the adaptive floor carved ${adaptive:.3f}x, not less than the fixed floor ${fixed32:.3f}x'
	assert adaptive <= 3.6, 'the adaptive floor carved ${adaptive:.3f}x over 8 MB live (expected live + 16 MB, ~3x)'
}

// cx-home/v#14: a 2 MB live set paced to the fixed 32 MB floor carved ~17x its
// live set (pi-digits 3000: 63.6 MB peak, Python 9.7). The adaptive floor gives
// it a 4 MB floor, so the carved high-water stays near live + 4 MB.
fn test_the_adaptive_floor_follows_a_tiny_live_set() {
	which := os.getenv('VGC_LIVE_CHILD')
	if which == 'tiny' {
		child(tiny_live_bytes)
		return
	}
	if which != '' {
		return
	}
	// The band is held up for both runs (the wall-time pacer and a 50 ms
	// collector stall per cycle, as in test_the_bound_has_a_floor), so the pair
	// reads the two floors and not two draws of the runner's band. Left to
	// itself the band reads the collector's work CPU (cx-home/v#42), and Linux
	// CI's walks-forced mode carved only 10.5 MB under the fixed floor
	// (38745420552, fork 7bff2f5641; the same tree's default and markers-forced
	// modes passed, and the descendant 4dd5d7dd25 passed all three).
	band := 'VGC_PACER_WALL=1 VGC_TEST_COLLECTOR_STALL_US=50000 '
	fixed := ratio(band + 'VGC_HEADROOM_ADAPTIVE_FLOOR=0 ', 'tiny') * f64(tiny_live_bytes) / 1048576.0
	adaptive := ratio(band, 'tiny') * f64(tiny_live_bytes) / 1048576.0
	println('vgc_headroom_live: 2 MB live, band held up — carved high fixed floor ${fixed:.1f} MB, adaptive floor ${adaptive:.1f} MB')
	// the control: the fixed floor carves live + its 32 MB floor (~34 MB); the
	// adaptive floor's bar is the one this test exists for: live + 4 MB (~6 MB)
	assert fixed >= 16.0, 'the fixed floor carved only ${fixed:.1f} MB over 2 MB live (expected 18-34 MB)'
	assert fixed >= adaptive * 2.0, 'the adaptive floor carved ${adaptive:.1f} MB, not under half the fixed floor ${fixed:.1f} MB'
	assert adaptive <= 14.0, 'the adaptive floor carved ${adaptive:.1f} MB over 2 MB live (expected ~6-10 MB)'
}

// cx-home/v#14, cx-private#1886: ONE allocating thread paces to Go's GOGC=100
// goal, clamp(1 x marked, 2 MB, 32 MB), so the 8 MB set carves ~2x, not the
// ~3x of clamp(2 x marked, 4 MB, 32 MB) (fasta 19.5 -> 17.4 MB, pi-digits
// 25.0 -> 18.8, Python 8.8 / 9.8). VGC_PACE_THREADS=4 runs the same churn on
// four allocating threads, whose floor keeps the 2 x marked base the
// per-thread scaling multiplies (integrator ruling 2026-10-11T08:19:47Z).
fn churn_threads(live_bytes int, nthreads int) {
	mut head := &Node(unsafe { nil })
	for i in 0 .. live_bytes / node_bytes {
		mut n := &Node{
			next: head
		}
		n.pad[0] = u64(i)
		head = n
	}
	gc_collect()
	// each thread samples the carved high-water as it churns and returns it
	mut hs := []thread usize{}
	for t in 0 .. nthreads {
		hs << spawn fn (t int) usize {
			mut s := u64(0)
			mut h := usize(0)
			for i in 0 .. 96 * 1024 * 1024 / chunk / 4 {
				x := []u8{len: chunk, init: u8(i + t)}
				s += x[i % chunk]
				if i % 64 == 0 {
					c := gc_memory_use()
					if c > h {
						h = c
					}
				}
			}
			return h + usize(s % 2)
		}(t)
	}
	sink := u64(0)
	mut high := gc_memory_use()
	for th in hs {
		c := th.wait()
		if c > high {
			high = c
		}
	}
	mut kept := 0
	for n := head; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('RATIO=${f64(high) / f64(live_bytes):.3f} sink=${sink} kept=${kept}')
}

fn test_one_allocating_thread_paces_to_twice_the_live_set() {
	which := os.getenv('VGC_LIVE_CHILD')
	if which == 'small4' {
		churn_threads(small_live_bytes, 4)
		return
	}
	if which != '' {
		return
	}
	// The floors show only where the band asks for more than them, and left to
	// itself the band is the runner's (cx-home/v#42): Linux CI's walks-forced
	// mode read 2.066x for both floors on c44b0e0049 (CI 38488246197), the
	// band at its base. Held up as in test_the_bound_has_a_floor, the pair
	// reads the floors alone (macOS: 2.066x / 3.115x).
	band := 'VGC_PACER_WALL=1 VGC_TEST_COLLECTOR_STALL_US=50000 '
	one := ratio(band, 'small')
	one_old := ratio(band + 'VGC_ONE_THREAD_PCT=100 VGC_HEADROOM_FLOOR_LO1_MB=4 VGC_HEADROOM_LIVE_PCT=200 ', 'small')
	println('vgc_headroom_live: 8 MB live, one allocating thread, band held up — ${one:.3f}x (GOGC=100 floor), ${one_old:.3f}x (2 x marked)')
	assert one <= 2.5, 'one allocating thread carved ${one:.3f}x over 8 MB live (expected ~2x: live + 1 x marked)'
	assert one < one_old, 'the 1 x marked floor carved ${one:.3f}x, not less than ${one_old:.3f}x'
	// four threads against one, both left to the band as before (the stall would
	// let four allocating threads run ahead of any floor)
	one_free := ratio('', 'small')
	four := ratio('', 'small4')
	println('vgc_headroom_live: 8 MB live, four allocating threads — ${four:.3f}x (one thread ${one_free:.3f}x)')
	assert four > one_free, 'four allocating threads carved ${four:.3f}x, not more than one thread ${one_free:.3f}x: the per-thread floor lost its 2 x marked base'
}

// start_child: start-up's allocation with nothing collected yet — 8 MB of 4 KB
// transients from the process's first allocation, the carved high-water
// (gc_memory_use) read as it goes.
fn start_child() {
	mut high := gc_memory_use()
	mut sink := u64(0)
	for i in 0 .. 8 * 1024 * 1024 / chunk {
		t := []u8{len: chunk, init: u8(i)}
		sink += t[i % chunk]
		c := gc_memory_use()
		if c > high {
			high = c
		}
	}
	println('CARVED=${f64(high) / f64(1024 * 1024):.3f} sink=${sink}')
}

fn carved_mb(env string) f64 {
	r := os.execute('VGC_LIVE_CHILD=start ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	for l in r.output.split_into_lines() {
		if l.starts_with('CARVED=') {
			return l.all_after('CARVED=').all_before(' ').f64()
		}
	}
	panic(r.output)
}

// cx-home/v#56 (cx-private#1977): the first collection triggers at ONE
// allocating thread's floor (vgc_headroom_floor_lo1, 1 MB) — start-up is one
// thread — so a program's start-up carves about that much before its first
// cycle, not the several-thread floor (4 MB) it carved before; the spans it
// carved stayed committed for the run (json-codec 1 KB: peak RSS 16.39 MB at
// the 4 MB trigger, 15.20 MB at 1 MB). The pair reads the trigger alone: the
// same churn with the one-thread floor raised to the old trigger carves past it.
fn test_the_first_collection_triggers_at_the_one_thread_floor() {
	if os.getenv('VGC_LIVE_CHILD') != '' {
		return
	}
	one := carved_mb('')
	four := carved_mb('VGC_HEADROOM_FLOOR_LO1_MB=4 ')
	println('vgc_headroom_live: start-up churn carved ${one:.3f} MB at the default first trigger, ${four:.3f} MB with it at 4 MB')
	assert four >= 4.0, 'with the first trigger at 4 MB the churn carved only ${four:.3f} MB'
	assert one < 3.0, 'the first collection did not come at the one-thread floor: ${one:.3f} MB carved (bar 3 MB)'
}

// cx-home/v#56 (cx-private#1977 L5), cx-examples#296 and #297: ONE allocating
// thread paces to a quarter of its marked set (vgc_one_thread_pct, 25): the GOGC
// term, the band's live-set cap and the floor's scale. 8 MB live under the
// held-up band carves about 1.25x the live set, where the half term
// (VGC_ONE_THREAD_PCT=50) carves about 1.5x and Go's GOGC=100
// (VGC_ONE_THREAD_PCT=100, the pacing before) about 2x.
fn test_one_allocating_thread_paces_to_a_quarter_of_its_live_set() {
	if os.getenv('VGC_LIVE_CHILD') != '' {
		return
	}
	band := 'VGC_PACER_WALL=1 VGC_TEST_COLLECTOR_STALL_US=50000 '
	quarter := ratio(band, 'small')
	half := ratio(band + 'VGC_ONE_THREAD_PCT=50 ', 'small')
	full := ratio(band + 'VGC_ONE_THREAD_PCT=100 ', 'small')
	println('vgc_headroom_live: 8 MB live, one allocating thread, band held up — ${quarter:.3f}x at 25 %, ${half:.3f}x at 50 %, ${full:.3f}x at 100 %')
	assert half < full, 'one thread at 50 % carved ${half:.3f}x, not less than ${full:.3f}x at 100 %'
	assert quarter < half, 'one thread at 25 % carved ${quarter:.3f}x, not less than ${half:.3f}x at 50 %'
	assert quarter <= 1.55, 'one thread at 25 % carved ${quarter:.3f}x over 8 MB live (expected ~1.25x)'
}

// cx-home/v#56: the quarter is the term at every small size — the 2 MB grace that
// held it at half of a small marked set (cx-examples#296, #297) is gone. 2 MB live
// carves less at 25 % than at 50 %, as 8 MB live (the test above) does, and at
// most 1.55x its live set.
fn test_a_small_live_set_paces_to_the_quarter_too() {
	if os.getenv('VGC_LIVE_CHILD') != '' {
		return
	}
	band := 'VGC_PACER_WALL=1 VGC_TEST_COLLECTOR_STALL_US=50000 '
	quarter := ratio(band, 'tiny')
	half := ratio(band + 'VGC_ONE_THREAD_PCT=50 ', 'tiny')
	println('vgc_headroom_live: 2 MB live, one allocating thread, band held up — ${quarter:.3f}x at 25 %, ${half:.3f}x at 50 %')
	assert quarter < half, 'one thread at 25 % carved ${quarter:.3f}x over 2 MB live, not less than ${half:.3f}x at 50 %'
	assert quarter <= 1.55, 'one thread at 25 % carved ${quarter:.3f}x over 2 MB live (expected ~1.25x)'
}

// cx-home/v#56: the one-thread percentage paces a SMALL heap — one whose marked
// set is under the live floor (32 MB). Past it one thread keeps Go's GOGC=100: at
// 100 MB marked the 50 % goal doubled the cycles, cost 20 % of the wall and carved
// a third arena (cx --from=json --to=json on 300k records: 2 arenas at 100 %, 3 at
// 50 %). The pair reads the scope alone: 40 MB live carves the same at 25 % and
// at 100 %, where 8 MB live (the tests above) carves less at 25 %.
fn test_one_allocating_thread_over_the_live_floor_paces_as_before() {
	if os.getenv('VGC_LIVE_CHILD') != '' {
		return
	}
	band := 'VGC_PACER_WALL=1 VGC_TEST_COLLECTOR_STALL_US=50000 '
	quarter := ratio(band, 'big')
	full := ratio(band + 'VGC_ONE_THREAD_PCT=100 ', 'big')
	println('vgc_headroom_live: 40 MB live, one allocating thread, band held up — ${quarter:.3f}x at 25 %, ${full:.3f}x at 100 %')
	diff := if quarter > full { quarter - full } else { full - quarter }
	assert diff <= 0.15, 'over the live floor the one-thread percentage still paced: ${quarter:.3f}x at 25 % against ${full:.3f}x at 100 %'
}
