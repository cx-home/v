// The minor cycle (cx-home/v#56 step 2): under VGC_YOUNG=1, after the first
// full cycle, the pacer's cycles are minor (sticky marks, the roots, the old
// objects on the cards, a sweep of the young) until VGC_YOUNG_MINORS of them
// have run; every young record an old object holds survives them (young/minor.v
// reads back what it stored: bad=0, the old chain intact), -d vgc_cm_verify
// finds no object a minor cycle missed, the regime off runs no minor cycle, and
// an explicit gc_collect is a full cycle.
module main

import os

fn build(name string, extra string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(),
		'vgc_minor_${os.getpid()}_${os.file_name(name).all_before('.')}${extra.replace(' ', '_').replace('-', '')}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc ${extra} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn done_line(out string) string {
	lines := out.split_into_lines().filter(it.starts_with('done steps='))
	assert lines.len == 1, out
	return lines[0]
}

fn minor_lines(out string) []string {
	return out.split_into_lines().filter(it.contains('] minor n='))
}

fn test_minor_cycles_keep_every_young_record_an_old_object_holds() {
	exe := build('young/minor.v', '')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_GCTRACE=2 STEPS=4000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	d := done_line(r.output)
	assert d.contains(' bad=0 '), r.output
	assert d.contains(' chain=65536 '), r.output
	minors := d.all_after('minors=').all_before(' ').int()
	assert minors > 0, 'no minor cycle ran:\n${r.output}'
	// the minor cycles reclaimed the young garbage: 64 MB allocated, the heap
	// stays near the 5 MB live set (58 MB allocated in all, heap 6 MB)
	assert d.all_after('alloc_mb=').all_before(' ').int() >= 48, r.output
	assert d.all_after('heap_mb=').all_before(' ').int() < 24, 'the heap grew through the minor cycles:\n${r.output}'
	ml := minor_lines(r.output)
	assert ml.len == minors, 'minor lines ${ml.len} for minors=${minors}:\n${r.output}'
	// a minor cycle found the holder's stores on the cards
	assert ml.any(it.all_after('card_spans=').all_before(' ').int() > 0), r.output
	assert ml.any(it.all_after('old_objs=').all_before(' ').int() > 0), r.output
	// a full cycle follows the eighth minor (the default VGC_YOUNG_MINORS)
	assert ml.all(it.all_after('minor n=').all_before(' ').int() <= 8), r.output
	assert ml.any(it.all_after('minor n=').all_before(' ').int() == 8), 'never eight minors in a row:\n${r.output}'
}

fn test_the_verifier_finds_no_object_a_minor_cycle_missed() {
	exe := build('young/minor.v', '-d vgc_cm_verify')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_GCTRACE=2 STEPS=4000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	d := done_line(r.output)
	assert d.contains(' bad=0 '), r.output
	assert d.all_after('minors=').all_before(' ').int() > 0, r.output
	assert d.ends_with(' missed=0'), r.output
	ml := minor_lines(r.output)
	assert ml.len > 0, r.output
	assert ml.all(it.ends_with(' missed=0')), r.output
}

fn test_the_configured_count_bounds_the_minors_in_a_row() {
	exe := build('young/minor.v', '')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_YOUNG_MINORS=2 VGC_GCTRACE=2 STEPS=4000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert done_line(r.output).contains(' bad=0 '), r.output
	ml := minor_lines(r.output)
	assert ml.len > 0, r.output
	assert ml.all(it.all_after('minor n=').all_before(' ').int() <= 2), r.output
	r0 := os.execute('VGC_YOUNG=1 VGC_YOUNG_MINORS=0 VGC_GCTRACE=2 STEPS=2000 ${os.quoted_path(exe)}')
	assert r0.exit_code == 0, r0.output
	assert done_line(r0.output).contains(' minors=0 '), r0.output
	assert minor_lines(r0.output).len == 0, r0.output
}

fn test_no_minor_cycle_with_the_regime_off() {
	exe := build('young/minor.v', '')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_GCTRACE=2 STEPS=2000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	d := done_line(r.output)
	assert d.contains(' bad=0 '), r.output
	assert d.contains(' minors=0 '), r.output
	assert minor_lines(r.output).len == 0, r.output
	assert d.all_after('heap_mb=').all_before(' ').int() < 24, r.output
}

// cx-home/v#56 step 2: an old object outside the permanent generation that
// lives in a permanent span (allocated into a free slot after the promotion,
// made old by a full cycle) keeps the young record it alone holds across the
// minor cycles — the permanent rescan of its dirty span scans it beside the
// permanent objects (vgc_rescan_perm_span); before the fix only the permanent
// objects were scanned, the record was swept, and the read-back was torn.
fn test_an_old_object_in_a_permanent_span_keeps_its_young_record_across_a_minor_cycle() {
	exe := build('young/minor_perm.v', '')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_GCTRACE=2 STEPS=4000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains(' same_span='), r.output
	assert r.output.all_after('same_span=').int() > 0, 'no new cell took a permanent span:\n${r.output}'
	assert r.output.all_after('minors=').int() > 0, 'no minor cycle ran:\n${r.output}'
	assert r.output.contains(' bad=0 '), r.output
}

fn test_the_verifier_counts_no_miss_over_the_permanent_spans() {
	exe := build('young/minor_perm.v', '-d vgc_cm_verify')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_GCTRACE=2 STEPS=4000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains(' bad=0 '), r.output
	assert r.output.all_after('minors=').int() > 0, r.output
	assert r.output.all_after('missed=').int() == 0, r.output
}
