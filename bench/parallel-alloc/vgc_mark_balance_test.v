// vgc_mark_balance_test.v — a tree's mark is shared between the markers
// (cx-home/v#56 lever 13; vgc_work_balance and vgc_drain_mark_parallel in
// vlib/builtin/vgc_gc_d_vgc.c.v). A depth-first mark of a binary tree holds
// one pending child a level, a grey stack of about the tree's depth: it never
// fills a 256-entry buffer, so the other markers get work only from the busy
// marker's balance — and the balance gave work only from a buffer of 64
// entries or more, so one marker walked the whole tree while the others spun.
// binary-trees 18 (its live tree, cx native and cx interpreted): the 32 MB
// full read 12–13 ms at two markers on the levers' builds, the one-marker
// time (VGC_MARK_WORKERS=1: 11.3–12.2 ms), against 6.3–9.2 ms on the old
// collector, and at 49 MB cx interpreted read 15–19 ms at two, four and
// eight markers alike; the slower marks failed the concurrent cycle's birth
// forecast, so the fulls after them stopped the world (measure/
// collector-epic-91, lever 12: 33 of 100 fulls concurrent against the old
// collector's 79 of 112, summed pause 1,364 ms against 637).
// mark/tree.v (DEPTH=19: 524,287 nodes, ~16 MB) under VGC_CM=0 (every cycle
// stops the world) and VGC_MARK_PAR_MIN_US=0 (the configured markers every
// cycle), VGC_GCTRACE=2: the phase line's mshare= is the busiest marker's
// share of the objects the parallel drains scanned. Red: two markers read
// mshare ~100 (one marker scanned the tree). Green: the middle of the forced
// cycles reads at most 75 at two markers and at most 50 at four, and the
// tree reads back whole (nodes, sum, bad=0) as it does on one marker.
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'mark', 'tree.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_mark_balance_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

struct Run {
	done   string
	shares []int
}

fn run(exe string, markers int) Run {
	r :=
		os.execute('VGC_CM=0 VGC_MARK_PAR_MIN_US=0 VGC_MARK_WORKERS=${markers} VGC_GCTRACE=2 DEPTH=19 COLLECTS=5 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines()
	froms := lines.filter(it.starts_with('from='))
	dones := lines.filter(it.starts_with('done nodes='))
	assert froms.len == 1 && dones.len == 1, r.output
	from := froms[0].all_after('from=').int()
	mut shares := []int{}
	for l in lines {
		if !l.starts_with('[gc ') || !l.contains('] phases ') {
			continue
		}
		if l.all_after('[gc ').all_before(']').int() < from {
			continue
		}
		assert l.contains(' markers=${markers} '), 'a forced cycle not at ${markers} markers: ${l}'
		assert l.contains(' mshare='), 'no mshare= on the phase line: ${l}'
		shares << l.all_after(' mshare=').all_before(' ').int()
	}
	assert shares.len >= 5, 'fewer than five forced cycles traced:\n${r.output}'
	d := dones[0].all_before(' cycles=')
	println('vgc_mark_balance markers=${markers}: ${d} mshare=${shares}')
	return Run{
		done:   d
		shares: shares
	}
}

fn middle(a []int) int {
	mut s := a.clone()
	s.sort()
	return s[s.len / 2]
}

fn test_two_markers_share_a_tree() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	one := run(exe, 1)
	two := run(exe, 2)
	assert one.done.contains(' bad=0'), one.done
	assert two.done == one.done, 'two markers read the tree back differently: ${two.done} against ${one.done}'
	m := middle(two.shares)
	assert m <= 75, 'two markers: the busiest scanned ${m} % of the tree (the middle of ${two.shares})'
}

fn test_four_markers_share_a_tree() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	one := run(exe, 1)
	four := run(exe, 4)
	assert four.done == one.done, 'four markers read the tree back differently: ${four.done} against ${one.done}'
	m := middle(four.shares)
	assert m <= 50, 'four markers: the busiest scanned ${m} % of the tree (the middle of ${four.shares})'
}
