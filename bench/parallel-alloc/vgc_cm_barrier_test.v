// vgc_cm_barrier_test.v — the concurrent mark (the `-gc e` default since
// cx-private#1910) keeps every live record whole while mutators move the only
// reference to it into already-scanned objects by every path: a newborn's fill,
// an old object's field, an old array buffer, an old map, a channel to another
// thread (concurrent_barrier/cm_barrier.v). Built with -d vgc_cm_nobarrier (the
// termination re-scan skipped) the same program reclaims live records — the
// teeth: on 2c5782a5ca's concurrent collector (alloc-black without a re-scan of
// the newborn's span, no channel barrier) the default build was red too.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_cm_barrier_test.v
module main

import os

fn build(extra string) string {
	src := os.join_path(@DIR, 'concurrent_barrier', 'cm_barrier.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_cm_barrier_${os.getpid()}${extra.replace(' ', '_').replace('-', '')}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc ${extra} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_every_store_path_keeps_the_record() {
	exe := build('')
	defer {
		os.rm(exe) or {}
	}
	for t in [2, 8] {
		r := os.execute('T=${t} STEPS=40000 ${os.quoted_path(exe)}')
		assert r.exit_code == 0, 'T=${t}: ${r.output}'
		assert r.output.contains(' bad=0'), 'T=${t}: ${r.output}'
	}
}
