// cx-home/v#62: the per-thread floor over a small marked set (under the several-thread floor,
// 4 MB) is held to 8 x the marked set at any cost reading. A server marks 1-2 MB and its stamp
// counts 3-5 handlers on a busy cycle: one costly reading lifted the floor to 4 MB x nt, a
// 20-31 MB goal, and that goal's free pool stood at the server's peak. A batch (5-14 MB marked)
// keeps the floor x nt. Drives the white-box self-check in module builtin
// (vgc_small_live_floor_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_small_live_floor_test.v
module main

fn test_a_small_marked_set_holds_the_per_thread_floor_to_eight_times_marked() {
	rc := vgc_small_live_floor_selftest()
	assert rc == 0, 'vgc_small_live_floor_selftest check ${rc}'
}
