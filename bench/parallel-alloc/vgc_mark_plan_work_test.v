// https://github.com/cx-home/cx-platform-reference/issues/15: after a parallel cycle the
// marker plan reads the mark's one-marker equivalent when it is under the line, not the
// markers times the wall (which counts their idle spin). cx's CSV -> sqlite3 bulk load
// flapped 1/4 markers every other cycle on a 4 MB mark: 320 of 594 cycles on one marker
// at 935 us against 372 us on four. Drives the white-box self-check in module builtin
// (vgc_mark_plan_work_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_mark_plan_work_test.v
module main

fn test_a_parallel_small_mark_keeps_its_markers() {
	rc := vgc_mark_plan_work_selftest()
	assert rc == 0, 'vgc_mark_plan_work_selftest check ${rc}'
}
