// vgc_young_live_bound_test.v — the young regime's minor cycles serve a live
// set under the bound (cx-home/v#56 lever 12; vgc_young_live_max and
// vgc_young_end in vlib/builtin/vgc_gc_d_vgc.c.v): a full cycle whose marked
// set reads at or over VGC_YOUNG_LIVE_MB (default 32, the live floor the
// one-thread pacing uses; 0 = no bound) leaves the regime disarmed — no minor
// cycle until a full cycle reads under the bound again, and the barrier's
// gate back to the permanent range, so a pointer store into an old object
// calls nothing. Under the bound the regime is armed as before. Over a large
// live set the minors' stops cost more than the concurrent full cycles they
// replace: binary-trees 18 (measure/collector-epic-90, levers 8–11b, x3
// quiet) read cx interpreted 7.56 s against the old collector's 5.86 (589
// minors, 582 of them at 32 MB marked or more) and cx native 0.61 against
// 0.54 (16 of 22 minors past it, the barrier on all run). young/live_bound.v
// under VGC_YOUNG=1: red on 0746d58174 (48 MB live: minors >= 8, calls=64);
// green: 48 MB live reads minors=0 calls=0; 8 MB live, and 48 MB with the
// bound lifted, read minors >= 1 and barrier calls (one a card: records on one page share it).
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'young', 'live_bound.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_live_bound_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -d vgc_wb_count -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn run(exe string, env string) (int, int) {
	r := os.execute('VGC_YOUNG=1 RECS=64 REPEAT=1000 ${env} ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines().filter(it.starts_with('done bad='))
	assert lines.len == 1, r.output
	d := lines[0]
	println('vgc_young_live_bound ${env}: ${d}')
	assert d.contains(' bad=0 '), r.output
	return d.all_after('calls=').all_before(' ').int(), d.all_after('minors=').all_before(' ').int()
}

fn test_a_live_set_past_the_bound_runs_no_minor_and_no_barrier() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	calls, minors := run(exe, 'LIVE_MB=48 WAVE_MB=96')
	assert minors == 0, 'a 48 MB live set ran ${minors} minor cycles past the 32 MB bound'
	assert calls == 0, 'a store into an old object past the bound called the barrier ${calls} times'
}

fn test_a_live_set_under_the_bound_keeps_the_regime() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	calls, minors := run(exe, 'LIVE_MB=8 WAVE_MB=96')
	assert minors >= 1, 'an 8 MB live set ran no minor cycle under the bound'
	assert calls > 0, 'an 8 MB live set: no barrier call for 64 stored records'
}

fn test_the_bound_lifted_keeps_the_regime_at_any_size() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	calls, minors := run(exe, 'VGC_YOUNG_LIVE_MB=0 LIVE_MB=48 WAVE_MB=96')
	assert minors >= 8, 'VGC_YOUNG_LIVE_MB=0: a 48 MB live set ran ${minors} minor cycles'
	assert calls > 0, 'VGC_YOUNG_LIVE_MB=0: no barrier call for 64 stored records'
}
