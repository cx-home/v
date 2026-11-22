// vgc_young_array_wait_test.v — the results of an array of threads survive the
// minor cycles after `ts.wait()` (cx-core-code#279). The array waiter allocates
// the answer array, then joins the threads in order and stores each result into
// the array's buffer. A minor cycle during a join marks the answer array
// (sticky: old from then on); the next result, fresh young arrays, was stored
// with a raw C store and no barrier, so no card named the answer array, and the
// minors after the wait traced nobody to that result's arrays and swept them
// while the caller still read them (cx's fused group-by, the hop after
// cx-home/v#80's return box: wrong sums under VGC_YOUNG=1 in 1-6 % of runs).
// Shape: young/array_wait.v, 20 rounds of 4 workers; the first worker churns
// (minors) only once the main thread is inside the wait, then builds its
// result; the main thread churns blocks of the results' size after the wait,
// then checks every value. bad = results whose values changed.
// Red on e9c643f6d: bad=18..19 of 20 rounds under VGC_YOUNG=1 VGC_NEXT_GC_MB=1
// (VGC_YOUNG=0: 0).
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'young', 'array_wait.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_array_wait_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_the_results_an_array_waiter_stores_into_an_old_answer_array_survive_the_minors_after_it() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for env in ['VGC_YOUNG=1 VGC_NEXT_GC_MB=1', 'VGC_YOUNG=1 VGC_NEXT_GC_MB=1 WORKERS=12'] {
		r := os.execute('${env} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, r.output
		lines := r.output.split_into_lines().filter(it.starts_with('done bad='))
		assert lines.len == 1, r.output
		println('vgc_young_array_wait ${env}: ${lines[0]}')
		assert !lines[0].contains('minors=0'), 'no minor cycle ran: ${lines[0]}'
		assert lines[0].starts_with('done bad=0 '), lines[0]
	}
}
