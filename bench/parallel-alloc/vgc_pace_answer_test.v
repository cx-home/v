// cx-home/v#62: the 64 KB count paces as several only when it reaches half the live mutators at
// this stop and the stop before. A server holds every thread it runs (87 at http-json-echo k=28
// C=256) and only a few cross 64 KB between stops (at most 7 of 87): one thread, whatever its
// marked set, so one burst no longer flips it to several and holds it there (server peak
// 39-43 MB against 30, misc-epic-66/-69). A batch runs its k workers over 64 KB every cycle
// (k of k+2 threads): several. Drives the white-box self-check in module builtin
// (vgc_pace_answer_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_answer_test.v
module main

fn test_the_64kb_count_paces_as_several_only_at_half_the_live_mutators() {
	rc := vgc_pace_answer_selftest()
	assert rc == 0, 'vgc_pace_answer_selftest check ${rc}'
}
