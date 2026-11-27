// vgc_flat_cap_oversub_test.v — past the core count, the flat headroom cap
// scales with the allocating threads per core
// (https://github.com/cx-home/cx-private/issues/2040).
//
// cx-home/v#16 scales the flat cap (vgc_headroom_cap) by ceil(threads / 4), at
// most x4 — flat from 13-16 threads on. Every stop holds all the allocating
// mutators, so with more allocating threads than cores the cycle rate per thread
// climbs and the stops dominate: cx's json-codec 1 MB at [par 56] on dev2
// (28 cores) spent 842-932 ms of stop-the-world pause in a 1.23-1.28 s wall
// (Python 3.12 Pool(56): 0.763 s); pinned to 384 MB of headroom it ran 0.70 s
// at a 1,019 MB peak (Python's 1,652). At and under the core count the x4 stays
// (k=28's peak sits ~490 MB against Python's 519-1,228).
// Bars (vgc_flat_cap_mult, white-box in module builtin):
//   - up to the core count: x ceil(threads / 4), at most x4, as cx-home/v#16;
//   - past it: x ceil(4 x threads / cores) — 56 threads on 28 cores: x8;
//   - VGC_HEADROOM_OVERSUB=0 keeps the x4 everywhere (vgc_flat_cap_mult_selftest
//     reads the rule, not the env).
//
// Run: ./v test bench/parallel-alloc/vgc_flat_cap_oversub_test.v
module main

fn test_the_flat_cap_scales_past_the_core_count() {
	rc := vgc_flat_cap_mult_selftest()
	assert rc == 0, 'vgc_flat_cap_mult_selftest check ${rc}'
}
