// vgc_young_full_cm_test.v — a cycle is planned from the last cycle of its
// kind (cx-home/v#56 lever 11; vgc_mark_last_work and the records
// vgc_minor_mark_last_ns / vgc_minor_mark_last_work_ns /
// vgc_minor_root_last_ns in vlib/builtin): the full cycle that closes a run
// of minor cycles is judged for the concurrent cycle (cx-private#1910:
// VGC_CM=2, the last mark's work at least VGC_CM_MIN_US and twice the last
// root scan) by the last FULL cycle's mark and root scan, and a minor's
// marker count by the last minor's work. Before, a minor wrote the shared
// records: the closing full read the minor's ~0.3 ms mark, under the line,
// and ran stop-the-world every time (binary-trees 18 cx interpreted: 88
// fulls, 1,450 ms of stops, 43 of 44 at 49 MB live over 5 ms, against the
// old collector's 112 fulls at 559 ms, 84 of them concurrent); and the minor
// after a full planned from the full's 17 ms mark took eight markers for its
// 0.3 ms mark (643 minors a run). young/wave.v under VGC_YOUNG=1 and
// VGC_GCTRACE=2: 48 MB live, a full cycle, then 96 MB of young garbage
// nothing holds — the minors' marks are the roots and a few cards, the fulls
// that close their runs mark the 48 MB (a ~10 ms mark, past the line).
// Red on 0a727bcc8c: the closing fulls are stop-the-world (no `cm stop1=`
// line) and the first minor after a full reads markers=4-8; green: every
// closing full is a concurrent cycle and every minor whose mark reads under
// VGC_MARK_PAR_MIN_US (1 ms), as its predecessor's did, ran one marker.
module main

import os

fn build(name string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(),
		'vgc_full_cm_${os.getpid()}_${os.file_name(name).all_before('.')}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

// gc_id answers the cycle number of a `[gc N] ...` trace line, -1 for any other
fn gc_id(line string) int {
	if !line.starts_with('[gc ') {
		return -1
	}
	return line.all_after('[gc ').all_before(']').int()
}

fn field(line string, key string) int {
	if !line.contains(' ${key}=') {
		return -1
	}
	return line.all_after(' ${key}=').all_before(' ').int()
}

struct Cycles {
mut:
	first_minor int = -1
	minors      []int
	fulls       []int
	cm          []int
	mark_us     map[int]int
	markers     map[int]int
	done        string
}

// run_wave runs young/wave.v with `env` on top of the young regime and the
// trace, and reads the cycles by kind
fn run_wave(env string) (Cycles, string) {
	exe := build('young/wave.v')
	defer {
		os.rm(exe) or {}
	}
	r :=
		os.execute('VGC_YOUNG=1 VGC_GCTRACE=2 VGC_ONE_THREAD_PCT=100 WAVE_MB=96 ${env} ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines()
	done := lines.filter(it.starts_with('done bad='))
	assert done.len == 1, r.output
	assert done[0].contains(' bad=0 '), r.output
	mut c := Cycles{
		done: done[0]
	}
	for line in lines {
		id := gc_id(line)
		if id < 0 {
			continue
		}
		if line.contains('] minor n=') {
			c.minors << id
			if c.first_minor < 0 {
				c.first_minor = id
			}
		} else if line.contains('] young cards=') {
			c.fulls << id
		} else if line.contains('] cm stop1=') {
			c.cm << id
		} else if line.contains('] phases ') {
			c.mark_us[id] = field(line, 'mark')
			c.markers[id] = field(line, 'markers')
		}
	}
	assert c.first_minor >= 0, 'no minor cycle ran\n${r.output}'
	return c, r.output
}

// one marker (the stop-the-world full over 48 MB is a ~10 ms stop, so a
// concurrent full's ~1 ms of stops always pays and no back-off follows) and
// no birth forecast (VGC_CM_BORN_PCT=0: the forecast reads the box's load):
// the concurrent test is then the last mark's work and root scan alone
fn test_the_full_that_closes_a_run_of_minors_takes_the_concurrent_cycle() {
	c, out := run_wave('VGC_MARK_WORKERS=1 VGC_CM_BORN_PCT=0')
	closing := c.fulls.filter(it > c.first_minor)
	assert closing.len >= 1, 'no full cycle closed a run of minors\n${out}'
	mut stw := []int{}
	for id in closing {
		if id !in c.cm {
			stw << id
		}
	}
	println('vgc_young_full_cm: minors=${c.minors.len} closing_fulls=${closing.len} stw_closing=${stw} ${c.done}')
	assert stw.len == 0, 'the full cycles ${stw} closed a run of minors stop-the-world: judged for the concurrent cycle by the minor\'s mark, not the last full\'s\n${out}'
}

fn test_a_minor_cycle_plans_its_markers_from_the_last_minor() {
	c, out := run_wave('')
	minors := c.minors
	// a minor is planned from the last minor: one whose mark and whose
	// predecessor's mark both read under the line ran one marker (the minor
	// after a full inherited the full's plan before)
	mut wide := []int{}
	mut prev_us := -1
	for id in minors {
		m := c.mark_us[id] or { -1 }
		n := c.markers[id] or { -1 }
		if m >= 0 && m < 1000 && prev_us >= 0 && prev_us < 1000 && n > 1 {
			wide << id
		}
		prev_us = m
	}
	println('vgc_young_minor_markers: minors=${minors.len} wide_minors=${wide} ${c.done}')
	assert wide.len == 0, 'the minor cycles ${wide} ran several markers on a mark under 1 ms: planned from the full\'s mark, not the last minor\'s\n${out}'
}

// the back-off (cx-private#1910: a concurrent cycle whose two stops read at
// least half the last stop-the-world pause sends the next 8, 16, 32, 64
// cycles to stop-the-world fulls) judges a concurrent full against the last
// stop-the-world FULL's pause: a minor's stop is not written there.
// young/minor_pause.v: 48 MB live, a full cycle (a ~10 ms stop), then young
// garbage until one minor has run (a ~1 ms stop). Red: pause1 reads the
// minor's stop; green: pause1 == pause0.
fn test_a_minor_cycle_is_not_the_pause_the_concurrent_cycle_is_judged_by() {
	exe := build('young/minor_pause.v')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_ONE_THREAD_PCT=100 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines().filter(it.starts_with('done bad='))
	assert lines.len == 1, r.output
	d := lines[0]
	println('vgc_young_minor_pause: ${d}')
	assert d.contains(' bad=0 '), r.output
	assert field(d, 'minors') >= 1, 'no minor cycle ran\n${r.output}'
	assert field(d, 'fulls') == 0, 'a full cycle ran during the wave\n${r.output}'
	pause0 := field(d, 'pause0_us')
	pause1 := field(d, 'pause1_us')
	assert pause0 >= 1000, 'the full cycle over 48 MB live read a ${pause0} us stop\n${r.output}'
	assert pause1 == pause0, 'the minor cycle\'s stop (${pause1} us) replaced the full\'s (${pause0} us) as the pause the next concurrent cycle is judged by\n${r.output}'
}
