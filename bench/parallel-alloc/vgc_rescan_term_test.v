// cx-examples#403: a concurrent cycle's termination re-scan fields one thread
// per 16 MB born in its middle, up to the marker pool it already holds. Near the
// end of 28 xlsx parses in one process the plan made before stop 1 read the last
// re-scan's ~100 objects, and the cycle re-scanned 8.8 M objects born in a 0.6 s
// middle on that one thread: a 3.0 s stop. Drives the white-box self-check in
// module builtin (vgc_rescan_term_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_rescan_term_test.v
module main

fn test_a_termination_rescan_fields_a_thread_per_sixteen_mb_born_in_the_middle() {
	rc := vgc_rescan_term_selftest()
	assert rc == 0, 'vgc_rescan_term_selftest check ${rc}'
}
