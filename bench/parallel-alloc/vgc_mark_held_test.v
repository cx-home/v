// cx-home/v#62: a stop that holds many mutators engages the mark pool on both
// sides of the pool's line. template-render on 20 mutators (cx-private#1923)
// ran 1,172 of 1,738 cycles on one marker (1.3 ms marks, over the 1 ms line)
// while the 20 waited: 4.7 s of stops in a 5.8 s run. Drives the white-box
// self-check in module builtin (vgc_mark_held_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_mark_held_test.v
module main

fn test_a_stop_of_many_mutators_engages_the_pool_on_both_sides_of_the_line() {
	rc := vgc_mark_held_selftest()
	assert rc == 0, 'vgc_mark_held_selftest check ${rc}'
}
