// cx-home/v#55: the marker plan reads a one-marker mark's work as its CPU
// time when the box stretched its wall. With 28 copies of one program on the
// box each copy's 0.3-1.3 ms mark read 2-8 ms of wall and woke up to seven
// markers that spun on an emptied grey set (json-codec 1 MB MP 0.86 of
// Python's scaling; 1.02 with VGC_MARK_WORKERS=1). This drives the white-box
// self-check in module builtin (vgc_mark_cpu_plan_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_mark_cpu_plan_test.v
module main

fn test_mark_plan_reads_cpu_time() {
	rc := vgc_mark_cpu_plan_selftest()
	assert rc == 0, 'vgc_mark_cpu_plan_selftest check ${rc}'
}
