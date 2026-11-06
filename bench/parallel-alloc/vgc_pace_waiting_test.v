// cx-platform-store#17 (burst_put's peak RSS): several allocating threads in a process that waits
// rather than computes — 16 writers on fsync used 0.46 cores — pace as one thread while the marked
// set is under the live floor; a busy process keeps GOGC=100 (cx-home/v#62). Drives the white-box
// self-check in module builtin (vgc_pace_waiting_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_waiting_test.v
module main

fn test_a_waiting_process_paces_as_one_thread() {
	rc := vgc_pace_waiting_selftest()
	assert rc == 0, 'vgc_pace_waiting_selftest check ${rc}'
}
