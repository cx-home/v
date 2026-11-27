// vgc_pace_recheck_test.v — cx-core-code#133: a collection the pacer starts is due when it
// starts. Several allocating threads read the trigger (heap_live >= next_gc) at about the same
// moment; one wins the phase CAS and collects, and a thread that read the trigger before that
// cycle's stop resumed after it and won the CAS again: a second cycle with nothing allocated
// since the first (its pace line reads acct=0, no thread over 64 KB since the stop). Its
// interval is a few microseconds, so the overhead band read the collector's cost as over 10 %
// of the mutators' time and doubled the headroom, and with the per-thread floor uncapped the
// next goal was 17 MB on a 2 MB live set: doubleselect 100000 (cx interpreted, dev2) peaked
// at 28-44 MB against Python 3.12's 24.4 MB, three such cycles of ~170 a run
// (VGC_GCTRACE=2, state/measure/perf-133). A paced call re-reads the trigger after it wins the
// CAS and stands down when the cycle it read is already done (Go's gcStart re-tests its
// trigger the same way); a forced collection (vgc_force_collect) always runs.
//
// pace_recheck/churn.v runs THREADS workers allocating small arrays over a small live set;
// the test runs it at VGC_GCTRACE=2 and asks that no collection after start-up read acct=0.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_pace_recheck_test.v
module main

import os

fn build_fixture() string {
	src := os.join_path(@DIR, 'pace_recheck', 'churn.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_pace_recheck_${os.getpid()}')
	r := os.execute('${os.quoted_path(@VEXE)} -gc e -prod -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

// back_to_back answers the collections after start-up (cycle 2 on) whose pace line reads
// acct=0, and the number of pace lines.
fn back_to_back(err string) (int, int) {
	mut n := 0
	mut pace := 0
	for line in err.split_into_lines() {
		if !line.starts_with('[gc ') || !line.contains('] pace nt=') {
			continue
		}
		pace++
		cycle := line.all_after('[gc ').all_before(']').int()
		if cycle >= 2 && line.contains(' acct=0 ') {
			n++
		}
	}
	return n, pace
}

fn run_fixture(exe string, env string) (int, int) {
	e := '${exe}.err'
	defer {
		os.rm(e) or {}
	}
	r := os.execute('env ${env} VGC_GCTRACE=2 ${os.quoted_path(exe)} 8 400000 2> ${os.quoted_path(e)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains('done'), r.output
	err := os.read_file(e) or { '' }
	return back_to_back(err)
}

fn test_a_paced_collection_is_due_when_it_starts() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	mut total := 0
	mut cycles := 0
	for _ in 0 .. 5 {
		n, pace := run_fixture(exe, 'X=1')
		total += n
		cycles += pace
	}
	assert cycles > 50, '${cycles} collections in five runs (want > 50 for the churn to mean anything)'
	assert total == 0, '${total} of ${cycles} collections after start-up read acct=0 (a paced cycle that started with nothing allocated since the last one)'
}

fn test_a_forced_collection_still_runs() {
	before := gc_cycles()
	gc_collect()
	gc_collect()
	assert gc_cycles() >= before + 2, 'gc_collect ran ${gc_cycles() - before} collections of 2'
}
