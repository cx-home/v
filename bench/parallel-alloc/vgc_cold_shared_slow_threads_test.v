// https://github.com/cx-home/cx-examples/issues/249: cx mandelbrot 16000 under bare [par]
// runs 28 workers over 0-2 MB marked, and no worker allocates 64 KB between two stops (the
// pacer reads acct=0 at every stop). Each worker warmed a private span in every class it
// touched: 3.0 MB of spans cached in the slots over 2.1 MB marked, 19.84 MB peak RSS against
// Python 3.12's 13.39 MB (bar 14.06; dev2 arm64 interpreted). With eight or more live
// mutators and no thread past the accounting flush at this stop or the one before, every
// class stays on its shared span. Drives the white-box self-check in module builtin
// (vgc_cold_shared_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_cold_shared_slow_threads_test.v
module main

fn test_many_slow_threads_over_a_small_live_set_share_each_class_span() {
	rc := vgc_cold_shared_selftest()
	assert rc == 0, 'vgc_cold_shared_selftest check ${rc}'
}
