// vgc_young_wave_test.v — a minor cycle's trigger is its share of the full
// cycle's headroom (cx-home/v#56 lever 8; vgc_minor_budget in
// vlib/builtin/vgc_gc_d_vgc.c.v): under VGC_YOUNG=1 a wave of young garbage
// over a live set that holds still is collected by minor cycles every eighth
// of the headroom the last full cycle left, so the heap stays near the live
// set. Before, a minor ran where a full would have — at twice the sticky
// marked set — and the young garbage filled the heap to that goal between two
// stops: binary-trees 18 after its stretch tree held 13 arenas and 270 MB of
// pool at 49 MB live (measure/collector-epic-80, the F traces). young/wave.v:
// 48 MB live, a full cycle, then 96 MB of 64-byte records nothing holds. Red
// on 9cfc37f87: minors=1, peak_mb 96-100 (the goal, twice the live set);
// green: eight minors or more, the peak within 16 MB over the live set.
module main

import os

fn build(name string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(),
		'vgc_wave_${os.getpid()}_${os.file_name(name).all_before('.')}')
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

fn test_a_wave_of_young_garbage_is_collected_by_minors_within_the_headroom() {
	exe := build('young/wave.v')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_GCTRACE=2 WAVE_MB=96 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	d := done_line(r.output)
	println('vgc_young_wave: ${d}')
	assert d.contains(' bad=0 '), r.output
	assert d.all_after('alloc_mb=').all_before(' ').int() >= 140, r.output
	goal := d.all_after('goal_mb=').int()
	assert goal >= 80, 'the full cycle after the live set read a goal under twice it: ${goal} MB\n${r.output}'
	minors := d.all_after('minors=').all_before(' ').int()
	peak := d.all_after('peak_mb=').all_before(' ').int()
	// the minors ran within the headroom: eight or more over 96 MB of garbage
	// against a full cycle's headroom of ~48 MB (one minor at the goal before)
	assert minors >= 8, 'the wave ran ${minors} minor cycles: a minor waits for the full cycle\'s goal\n${r.output}'
	// the heap stayed near the live set (48 MB): the young garbage between two
	// stops is an eighth of the headroom, not the whole of it
	assert peak <= 48 + 16, 'the wave carried the heap to ${peak} MB over a 48 MB live set\n${r.output}'
}
