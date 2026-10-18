// cx-home/v#52: the marker plan's back-off ends. A two-marker probe of the
// concurrent mark that lost against a baseline the start-up's small heap set
// was halved to one marker, and the back-off counted only parallel cycles, so
// it never ended: the stores-mt driver (cx-core-code native_linkage) at eight
// threads ran its whole run on one marker in three runs of five (a 6 ms
// middle against 1.1 ms; 570 ms against 220). This drives the white-box
// self-check in module builtin (vgc_mark_backoff_selftest): a probe the
// one-marker cycles prove a winner ends its back-off early, and one that truly
// lost ends it after its 32 cycles.
//
//   ../../v -gc e test bench/parallel-alloc/vgc_mark_backoff_test.v
module main

fn test_mark_backoff_ends() {
	rc := vgc_mark_backoff_selftest()
	assert rc == 0, 'vgc_mark_backoff_selftest check ${rc}'
}
