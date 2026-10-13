// vgc_perm_test.v — the permanent generation (cx-home/v#15 lever 2, `-gc e`):
// the live set of the first cycle after the embedder's vgc_set_permanent is
// pre-marked at every later cycle and never traced (there is no automatic
// promotion: permanent/perm_transient.v); a pointer stored into it afterwards is found
// through the span's dirty bit (vgc_wb_store, called before and after every
// pointer store) and the stop's re-scan. permanent/perm_gen.v stores the only
// reference to a fresh record into permanent objects by every path (a field, a
// nested value's field, an array buffer, a fixed array, a regrowing push, a
// map, a store through a pointer, a statement whose right-hand side collects)
// and reads every record back after cycles. The teeth: built with
// -d vgc_cm_nobarrier (the re-scan skipped) the same program reclaims live
// records. The verifier build (-d vgc_cm_verify) re-marks every cycle from
// zero and must count no miss.
//
// Six process runs (T=4 under every VGC_CM, the verifier under VGC_CM=1, the
// teeth, VGC_PERM=0): the FreeBSD CI VM (4 vCPU) runs the suite's walks-forced
// pass one test at a time, and ten runs of the fixture at a cycle per eighth
// step ran that pass past the job's hour.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_perm_test.v
module main

import os

fn build(extra string) string {
	return build_src('perm_gen.v', extra)
}

fn build_src(name string, extra string) string {
	src := os.join_path(@DIR, 'permanent', name)
	exe := os.join_path(os.vtmp_dir(),
		'vgc_perm_${os.getpid()}_${name.all_before('.')}${extra.replace(' ', '_').replace('-', '')}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc ${extra} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_every_store_path_into_a_permanent_object_keeps_the_record() {
	exe := build('')
	defer {
		os.rm(exe) or {}
	}
	for cm in ['', 'VGC_CM=1 ', 'VGC_CM=0 '] {
		r := os.execute('${cm}VGC_GCTRACE=2 T=4 STEPS=10000 ${os.quoted_path(exe)}')
		assert r.exit_code == 0, '${cm}T=4: ${r.output}'
		assert r.output.contains(' bad=0'), '${cm}T=4: ${r.output}'
		// the generation is on: the first cycle promoted, and the later
		// cycles re-scanned only the dirtied permanent spans
		assert r.output.contains('promoted=1'), '${cm}T=4: no promotion in ${r.output}'
		assert r.output.contains('] perm spans='), '${cm}T=4: ${r.output}'
	}
}

fn test_the_verifier_counts_no_miss() {
	exe := build('-d vgc_cm_verify')
	defer {
		os.rm(exe) or {}
	}
	// one run, every cycle concurrent (VGC_CM=1): the hardest regime for the
	// re-scan — the stop-the-world shape is the default run above
	r := os.execute('VGC_CM=1 VGC_GCTRACE=2 T=4 STEPS=20000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains(' bad=0'), r.output
	lines := r.output.split_into_lines().filter(it.contains('] perm spans='))
	assert lines.len > 0, r.output
	last := lines.last()
	assert last.contains(' missed=0 '), last
}

fn test_without_the_rescan_the_records_are_reclaimed() {
	exe := build('-d vgc_cm_nobarrier')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('T=4 STEPS=20000 ${os.quoted_path(exe)}')
	assert r.exit_code != 0 || !r.output.contains(' bad=0'), 'no teeth: ${r.output}'
}

fn test_vgc_perm_0_turns_the_generation_off() {
	exe := build('')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_PERM=0 VGC_GCTRACE=2 T=2 STEPS=10000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains(' bad=0'), r.output
	assert !r.output.contains('] perm spans='), r.output
}

// cx-home/v#15 / cx-private's repr-guard red on fe3095ab6: the first cycle
// promotes nothing unless the program asked (vgc_set_permanent), so ~8 MB held
// across it and dropped after is reclaimed by the next collections. The teeth:
// VGC_PERM_CYCLE=1 (the old automatic promotion) keeps it for the life of the
// process.
fn test_no_automatic_promotion_of_the_first_cycles_live_set() {
	exe := build_src('perm_transient.v', '')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_GCTRACE=2 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert !r.output.contains('] perm spans='), 'promoted without a request: ${r.output}'
	held := r.output.all_after('held_kb=').int()
	assert held < 2048, 'the dropped transient stayed live: ${held} KB\n${r.output}'
	t := os.execute('VGC_PERM_CYCLE=1 ${os.quoted_path(exe)}')
	assert t.exit_code == 0, t.output
	theld := t.output.all_after('held_kb=').int()
	assert theld > 6144, 'no teeth: VGC_PERM_CYCLE=1 held only ${theld} KB\n${t.output}'
}
