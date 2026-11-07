// cx-home/v#62, cx-private#1869: the 64 KB count paces as several when two or more threads
// crossed 64 KB at this stop and the stop before, whatever the live count. A server holds every
// thread it runs (27 at http-json-echo C=128 on dev2) and its reactors cross 64 KB between stops
// (acct 4-12 of 27); held to half the live mutators, the count read it as one thread at every
// cycle and the one-thread quarter drove ~330 collections a second — the p99 at 128 connections
// above Python's. One burst at one stop still keeps the previous answer. Drives the white-box
// self-check in module builtin (vgc_pace_answer_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_answer_test.v
module main

fn test_the_64kb_count_paces_as_several_at_two_threads_two_stops_running() {
	rc := vgc_pace_answer_selftest()
	assert rc == 0, 'vgc_pace_answer_selftest check ${rc}'
}
