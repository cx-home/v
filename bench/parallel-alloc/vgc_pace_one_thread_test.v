// cx-home/v#62: several allocating threads keep GOGC=100; only one allocating
// thread paces at the quarter (cx-home/v#56). template-render on 20 mutators
// (cx-private#1923) read as one thread to the ~1 MB stamp, since the quarter's
// budget split 20 ways keeps every worker under it, and paced ~1,500 of 1,852
// cycles at goal = marked + ~1.5 MB. Drives the white-box self-check in module
// builtin (vgc_pace_one_thread_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_one_thread_test.v
module main

fn test_several_allocating_threads_do_not_pace_at_the_one_thread_quarter() {
	rc := vgc_pace_one_thread_selftest()
	assert rc == 0, 'vgc_pace_one_thread_selftest check ${rc}'
}
