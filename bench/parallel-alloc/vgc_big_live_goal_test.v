// https://github.com/cx-home/cx-examples/issues/249 binary-trees 21: under [par] six to eleven
// allocating threads hold 110-190 MB marked, and the GOGC term with the per-thread floor paced
// the goal at 2-2.2 x marked — 398-407 MB peak RSS against Python 3.12's 270.42 MB (bar 283.9,
// dev1/dev2 arm64, interpreted, the cx-core-data#99 pair layout). Several allocating threads,
// no more than the CPUs, over a live set of 64 MB or more pace the goal at marked + 40 %.
// Drives the white-box self-check in module builtin (vgc_big_live_goal_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_big_live_goal_test.v
module main

fn test_several_threads_over_a_big_live_set_pace_the_goal_at_marked_plus_forty_percent() {
	rc := vgc_big_live_goal_selftest()
	assert rc == 0, 'vgc_big_live_goal_selftest check ${rc}'
}
