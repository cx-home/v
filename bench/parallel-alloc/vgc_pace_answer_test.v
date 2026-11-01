// cx-home/v#62: a marked set under the several-thread floor (4 MB) paces as one thread while
// the ~1 MB stamp counts at most one: a server's k handlers each allocate under the stamp on a
// sub-MB marked set, and pacing them as several gave a 4-5 MB goal on < 1 MB marked (hello-http
// k=12 C=256: +1.5-3 MB of resident peak against the head, misc-epic-59). template-render and
// json-codec at k=16..28 (5-14 MB marked) keep pacing as several. Drives the white-box
// self-check in module builtin (vgc_pace_answer_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_answer_test.v
module main

fn test_a_marked_set_under_the_several_thread_floor_paces_as_one_thread() {
	rc := vgc_pace_answer_selftest()
	assert rc == 0, 'vgc_pace_answer_selftest check ${rc}'
}
