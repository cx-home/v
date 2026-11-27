// vgc_headroom_climb_test.v — past the core count, an expensive cycle lifts the
// headroom straight to its ceiling instead of doubling it
// (https://github.com/cx-home/cx-private/issues/2040).
//
// The adaptive pacer doubles the headroom on each expensive reading (GC overhead
// over ~2 %), from the 8 MB floor. Every stop holds all the allocating mutators, so
// with more of them than cores each doubling step is a stop of every thread: cx's
// json-codec 1 MB at [par 56] on dev2 (28 cores) climbed 8 -> 256/512 MB over the
// run's first cycles while the live set grew 1 -> 380 MB (14 cycles, 587 ms of
// pause in a 1.04-1.12 s wall; Python 3.12 Pool(56) 0.78 s); pinned at 384 MB of
// headroom (VGC_NEXT_GC_MB=384, mc-2040d) 9 cycles, 0.70 s at a 1,019 MB peak.
// Bars (vgc_climb_jumps / vgc_climb_hr, white-box in module builtin):
//   - more allocating threads than cores (four cores or more): an expensive
//     reading takes the headroom to the cycle's ceiling (after every live and
//     per-thread cap), never past it;
//   - at or under the core count, under four cores, or VGC_HEADROOM_CLIMB=0:
//     the doubling, as before (vgc_climb_selftest reads the rule, not the env).
//
// Run: ./v test bench/parallel-alloc/vgc_headroom_climb_test.v
module main

fn test_an_oversubscribed_expensive_cycle_jumps_to_the_ceiling() {
	rc := vgc_climb_selftest()
	assert rc == 0, 'vgc_climb_selftest check ${rc}'
}
