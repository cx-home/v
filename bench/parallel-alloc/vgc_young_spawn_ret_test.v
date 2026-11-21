// vgc_young_spawn_ret_test.v — a spawned function's result survives the minor
// cycles that run between its return and the join (cx-home/v#80). The thread
// wrapper allocates and pins the return box BEFORE the call; a minor cycle
// during the call marks the box (sticky: it is old from then on); the call's
// result, fresh young arrays, is then stored into the box with a raw C store
// and no barrier, so no card names the box. After the worker exits the box is
// reached only through its pin, and the pin's shade of a marked object is a
// no-op: the next minor traced nobody to the result's arrays and swept them
// while the waiter still had to read them (cx's fused group-by: wrong sums under
// VGC_YOUNG=1, 5-17 % of runs).
// Shape: young/spawn_ret.v, 8 workers x 20 rounds, each churning garbage before
// building a 512-entry result; the main thread churns after every worker has
// returned and before the join. bad = results whose values changed.
// Red on 7d751140c9: bad=48..60 of 160 under VGC_YOUNG=1 VGC_NEXT_GC_MB=1
// (VGC_YOUNG=0: 0).
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'young', 'spawn_ret.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_spawn_ret_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_a_spawned_result_stored_into_an_old_box_survives_the_minors_before_the_join() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for env in ['VGC_YOUNG=1 VGC_NEXT_GC_MB=1', 'VGC_YOUNG=1 VGC_NEXT_GC_MB=1 WORKERS=16'] {
		r := os.execute('${env} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, r.output
		lines := r.output.split_into_lines().filter(it.starts_with('done bad='))
		assert lines.len == 1, r.output
		println('vgc_young_spawn_ret ${env}: ${lines[0]}')
		assert !lines[0].contains('minors=0'), 'no minor cycle ran: ${lines[0]}'
		assert lines[0].starts_with('done bad=0 '), lines[0]
	}
}
