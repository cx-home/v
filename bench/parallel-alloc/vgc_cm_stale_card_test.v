// vgc_cm_stale_card_test.v — https://github.com/cx-home/v/issues/84: under the permanent regime (an embedder called
// vgc_set_permanent; cx does at start-up) a store between cycles into a
// non-permanent object whose page lies in the permanent spans' range sets the
// page's card, and with the young generation off nothing clears it. In a later
// concurrent middle the generated C's gate sees the card set and returns before
// vgc_wb_store, so the span is not dirtied; the termination re-scan read cards
// only for permanent spans, so the store was never seen and the record it
// published could be swept while still referenced (concurrent_barrier/cm_stale_card.v).
// A -d vgc_cm_verify build re-marks the heap from zero at every termination and
// counts each object the concurrent mark missed. Before the re-scan read a set
// card as dirty on every span, it counted 16..128 missed objects in each of 4
// of 4 runs with the permanent regime on, and 0 without vgc_set_permanent (NOPERM=1).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_cm_stale_card_test.v
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'concurrent_barrier', 'cm_stale_card.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_cm_stale_card_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -d vgc_cm_verify -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_a_store_into_a_carded_page_during_a_concurrent_middle_is_seen() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for env in ['', '', '', 'NOPERM=1'] {
		r :=
			os.execute('${env} VGC_CM=1 T=6 STEPS=600 AGE_US=3000 BALLAST=300000 MS=1 ${os.quoted_path(exe)}')
		assert r.exit_code == 0, '${env}: ${r.output}'
		assert r.output.contains(' bad=0 missed=0'), '${env}: ${r.output}'
	}
}
