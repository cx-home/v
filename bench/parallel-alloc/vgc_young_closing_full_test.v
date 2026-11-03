// vgc_young_closing_full_test.v — the full cycle that follows a run of minor
// cycles collects at its share of the headroom (cx-home/v#56 lever 8, the
// closing full; vgc_minor_next in vlib/builtin/vgc_gc_d_vgc.c.v): under
// VGC_YOUNG=1 a wave of young records an old array keeps is marked a share at
// a time by the minors, and the full that follows them — forced once the
// marked set reads twice the last full's — runs one share on, so the heap
// stays near the records kept. Before, that full's trigger was the pacer's,
// twice the minors' marked set, a set a minor does not measure (it keeps the
// young spans the cards reach whole): binary-trees 18 read 361 MB marked
// after its eighth minor at 108 MB live, a goal of 723 MB, and carved five
// arenas before the full (measure/collector-epic-84, the F trace).
// young/hold.v: 48 MB live, a full cycle, then 72 MB of 64-byte records kept
// in an old array (eight minors, the marked set past twice the full's), then
// 96 MB of young garbage. Red on 370b61956f: peak_mb ~250 (twice the marked
// set at the run's end); green: the peak within 32 MB over the live set and
// the records kept (~126 MB).
module main

import os

fn build(name string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(),
		'vgc_hold_${os.getpid()}_${os.file_name(name).all_before('.')}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn done_line(out string) string {
	lines := out.split_into_lines().filter(it.starts_with('done bad='))
	assert lines.len == 1, out
	return lines[0]
}

fn test_the_full_that_closes_a_run_of_minors_runs_at_its_share_of_the_headroom() {
	exe := build('young/hold.v')
	defer {
		os.rm(exe) or {}
	}
	r :=
		os.execute('VGC_YOUNG=1 VGC_GCTRACE=2 VGC_ONE_THREAD_PCT=100 HOLD_MB=72 WAVE_MB=96 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	d := done_line(r.output)
	println('vgc_young_closing_full: ${d}')
	assert d.contains(' bad=0 '), r.output
	assert d.all_after('kept=').all_before(' ').int() == 72 * 1024 * 1024 / 64, r.output
	goal := d.all_after('goal_mb=').int()
	assert goal >= 80, 'the full cycle after the live set read a goal under twice it: ${goal} MB\n${r.output}'
	minors := d.all_after('minors=').all_before(' ').int()
	peak := d.all_after('peak_mb=').all_before(' ').int()
	// the minors ran within the headroom (one share each over 72 MB of
	// records kept, against a full cycle's headroom of ~48 MB)
	assert minors >= 8, 'the hold wave ran ${minors} minor cycles: a minor waits for the full cycle\'s goal\n${r.output}'
	kept := d.all_after('kept_mb=').all_before(' ').int()
	// the heap stayed near the live set and the records kept (48 + 72 MB):
	// the full that closes the run collects one share on (the share of the
	// full goal that follows it, 16 MB), not at twice the minors' marked set
	assert peak <= kept + 32, 'the wave carried the heap to ${peak} MB over ${kept} MB live + kept\n${r.output}'
}
