// https://github.com/cx-home/cx-platform-store/issues/29: a cycle that paced as several
// allocating threads goes back to the one-thread quarter only after vgc_pace_exit_stops quiet
// stops in a row (at most one thread stamped and at most one over 64 KB at each), not after
// the two that agree. A columnar store's put-docs batch runs its interpreter thread and 2-4
// workers (part write, lineage seal); under the quarter (headroom = marked / 4, ~1.5 MB on a
// 6 MB live set) the intervals are so short that the workers stay under 64 KB between stops,
// so two quiet stops come at once and the run falls back to the quarter, which keeps the
// intervals short: VGC_GCTRACE=2 read one=1 in 272 of 306 cycles (fields rows) and 411 of 440
// (attrs rows), with which shape escapes changing from run to run (attrs 196 cycles, then 440,
// same binary). At VGC_ONE_THREAD_PCT=100 both shapes paced alike (147 / 187 cycles) and the
// fields/attrs ratio read 1.077 wall / 1.088 user (bar 1.10). Entering several is unchanged
// (two agreeing readings; one burst keeps one), so a one-thread program never pays it.
// Drives the white-box self-check in module builtin (vgc_pace_exit_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_exit_test.v
module main

fn test_several_goes_back_to_the_quarter_only_after_quiet_stops_in_a_row() {
	rc := vgc_pace_exit_selftest()
	assert rc == 0, 'vgc_pace_exit_selftest check ${rc}'
}
