// cx-home/v#56 lever 16: the thread-stack scan's byte loop (vgc_stack_candidates, vgc_platform.h) answers
// exactly the offsets the byte loop read — every byte offset whose word fits below hi, value in the
// arenas' bounds, in address order — for any start, end and cap. Drives the white-box self-check in
// module builtin (vgc_stack_scan_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_stack_scan_test.v
module main

fn test_the_stack_scan_reads_every_byte_offset() {
	rc := vgc_stack_scan_selftest()
	assert rc == 0, 'vgc_stack_scan_selftest check ${rc}'
}
