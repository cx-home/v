// cx-home/v#56 (csv-aggregate 100 MB's peak RSS): the start-up collection's 64 KB count is no
// 'stop before' for the second collection to agree with — csv-aggregate read 2 of 2 threads at
// start-up and 2 of 3 at gc 1, paced gc 1 as several (headroom 4,096 KB) and peaked at 15.8 MB
// against Python 3.12's 14.1. Drives the white-box self-check in module builtin
// (vgc_pace_startup_prev_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_startup_prev_test.v
module main

fn test_the_start_up_count_is_no_stop_before() {
	rc := vgc_pace_startup_prev_selftest()
	assert rc == 0, 'vgc_pace_startup_prev_selftest check ${rc}'
}
