// https://github.com/cx-home/cx-examples/issues/249: cx mandelbrot n=2000 [par 4] keeps
// 0-1 MB marked, yet its four workers paced from the several-thread floor's 4 MB low
// clamp and each took the scaled stash batch (x16 at four threads): 15.6-15.9 MB peak
// RSS against Python 3.12's 13.41 MB (bar 14.08), where one thread reads 10.5 MB.
// A live set under the small-live bound (2 MB, VGC_SMALL_LIVE_KB) keeps the one-thread
// batch and half the low clamp. Drives the white-box self-check in module builtin
// (vgc_small_live_several_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_small_live_several_test.v
module main

fn test_a_small_live_set_under_several_threads_keeps_the_one_thread_batch_and_half_the_floor() {
	rc := vgc_small_live_several_selftest()
	assert rc == 0, 'vgc_small_live_several_selftest check ${rc}'
}
