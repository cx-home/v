// cx-home/v#62: a cycle that paces as several threads by the 64 KB count alone (every
// thread under the ~1 MB stamp) keeps the one-thread floor under 2 x marked, not the flat
// 4 MB floor the per-thread scaling multiplies: hello-http at k=12 (C=256) ran a 4-5 MB
// goal on a < 1 MB marked set, +1.5-3 MB of resident peak against the head (misc-epic-59).
// Drives the white-box self-check in module builtin (vgc_adaptive_floor_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_adaptive_floor_test.v
module main

fn test_several_threads_under_the_stamp_keep_the_one_thread_floor() {
	rc := vgc_adaptive_floor_selftest()
	assert rc == 0, 'vgc_adaptive_floor_selftest check ${rc}'
}
