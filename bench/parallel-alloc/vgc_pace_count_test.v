// https://github.com/cx-home/v/issues/94: the pacing decision (one allocating thread or several,
// vgc_pace_one_thread) counts a thread as allocating at a threshold that follows the cycle's
// budget (vgc_pace_count_min: budget / 64, between 8 KB and 64 KB), not at a fixed 64 KB. At
// 64 KB the count depended on the pacing it decided: under the quarter (a 1-2 MB budget) a
// worker with 2-4 % of the bytes stayed under 64 KB between stops and the run kept the quarter;
// under GOGC=100 (a 9 MB budget) the same worker read several. cx's put-docs (~4 MB live, the
// interpreter thread and 2-4 parquet workers) fell into either from run to run: one=1 in 10 of
// 110 cycles in one run and 209 of 219 in another, same workload; the cheaper of two kits read
// more collections than its parent (cx-home/v#94, cx-core-data#98).
// Drives the white-box self-check in module builtin (vgc_pace_count_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_count_test.v
module main

fn test_the_pacing_count_follows_the_cycle_budget() {
	rc := vgc_pace_count_selftest()
	assert rc == 0, 'vgc_pace_count_selftest check ${rc}'
}
