// vgc_concurrent_cached_span_test.v — under -d vgc_concurrent the mark-termination
// sweep protects every mcache-resident span, as the stop-the-world collector does
// (vgc_protect_cached_spans before vgc_do_sweep). Without it the concurrent sweep
// treated a span a thread still allocated from as an orphan: a partially-free one
// was relinked onto central.partial while its owner kept carving from it, a second
// thread popped it once full, and the allocation failed — `malloc(0x30)` / `V panic:
// memory allocation failure` within the first second of eight allocating threads
// beside a ninth forcing gc_collect() every 2 ms (cx-private #1757). The default
// collector ran the same program clean.
//
// concurrent_mt_sound/mt_sound.v is that reproduction (checksummed records and
// 33 KB..2 MB buffers in a rolling window per worker, every window re-verified);
// the test builds it with -d vgc_concurrent and runs it at 8 and 16 workers.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_concurrent_cached_span_test.v
module main

import os

fn build_fixture() string {
	src := os.join_path(@DIR, 'concurrent_mt_sound', 'mt_sound.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_concurrent_mt_sound_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -d vgc_concurrent -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_concurrent_sweep_leaves_cached_spans_to_their_owner() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	for t in [8, 16] {
		r := os.execute('T=${t} STEPS=20000 ${os.quoted_path(exe)}')
		assert r.exit_code == 0, 'T=${t}: ${r.output}'
		assert r.output.contains(' bad=0'), 'T=${t}: ${r.output}'
	}
}
