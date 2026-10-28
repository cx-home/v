// cx-examples#403: a stop that holds more mutators than the configured markers
// fields one marker per CPU they leave idle. 28 xlsx parses in one process
// marked 8 GB of parse results in a 650-920 ms stop with the eight configured
// markers while 20 cores waited; sixteen read 410 ms. Drives the white-box
// self-check in module builtin (vgc_mark_wide_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_mark_wide_test.v
module main

fn test_a_stop_of_many_mutators_fields_a_marker_per_idle_cpu() {
	rc := vgc_mark_wide_selftest()
	assert rc == 0, 'vgc_mark_wide_selftest check ${rc}'
}
