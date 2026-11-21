// vgc_first_goal_test.v — the first collection's goal can be set apart from the
// one-thread floor (cx-home/v#76).
//
// A program that builds a few MB it keeps at start-up crosses the first goal
// (the one-thread floor, vgc_headroom_floor_lo1) before its own work begins, and
// each start-up cycle frees almost nothing. Raising that floor (the only knob
// before) also moves every later cycle's floor. VGC_FIRST_GOAL_KB sets the first
// goal alone: with it at 4 MB a 3 MB live start-up runs no cycle before the work;
// the default keeps the one-thread floor, so a start-up that churns garbage is
// still collected before it carves 3 MB (vgc_headroom_live_test,
// test_the_first_collection_triggers_at_the_one_thread_floor).
//
// The child keeps live_mb MB of 48-byte linked nodes (or drops each node at
// once), prints START-UP-DONE on stderr, then walks what it kept. The parent runs
// it under VGC_GCTRACE=1 and counts the `[gc N]` lines before that mark.
//
//   ../../v -gc e test bench/parallel-alloc/vgc_first_goal_test.v
module main

import os

struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

fn child(live_mb int, keep bool) {
	mut head := &Node(unsafe { nil })
	for i in 0 .. live_mb * 1024 * 1024 / 48 {
		mut n := &Node{}
		if keep {
			n.next = head
		}
		n.pad[0] = u64(i)
		head = n
	}
	eprintln('START-UP-DONE')
	mut kept := 0
	for n := head; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('KEPT=${kept} CARVED=${f64(gc_memory_use()) / f64(1024 * 1024):.3f}')
}

struct StartUp {
	cycles int
	kept   int
	carved f64
}

fn start_up(env string, live_mb int, keep bool) StartUp {
	r :=
		os.execute('VGC_GOAL_CHILD=${live_mb} VGC_GOAL_KEEP=${int(keep)} VGC_GCTRACE=1 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	mut cycles := 0
	mut done := false
	mut kept := -1
	mut carved := -1.0
	for l in r.output.split_into_lines() {
		if l.starts_with('START-UP-DONE') {
			done = true
		} else if l.starts_with('[gc ') && l.contains(' marked=') && !done {
			cycles++
		} else if l.starts_with('KEPT=') {
			kept = l.all_after('KEPT=').all_before(' ').int()
			carved = l.all_after('CARVED=').f64()
		}
	}
	assert done, r.output
	return StartUp{
		cycles: cycles
		kept:   kept
		carved: carved
	}
}

fn test_a_kept_start_up_under_the_first_goal_runs_no_cycle() {
	which := os.getenv('VGC_GOAL_CHILD')
	if which != '' {
		child(which.int(), os.getenv('VGC_GOAL_KEEP') == '1')
		return
	}
	nodes := 3 * 1024 * 1024 / 48
	for _ in 0 .. 3 {
		set := start_up('VGC_FIRST_GOAL_KB=4096 ', 3, true)
		dflt := start_up('', 3, true)
		println('vgc_first_goal: 3 MB kept at start-up — ${set.cycles} cycles before the work with the first goal at 4 MB, ${dflt.cycles} at the default')
		assert set.kept == nodes && dflt.kept == nodes
		assert set.cycles == 0, 'with the first goal at 4 MB a 3 MB start-up ran ${set.cycles} cycles before its work'
		assert dflt.cycles >= 1, 'the default first goal is no longer the one-thread floor: a 3 MB start-up ran no cycle'
	}
}

// The first goal moves the first cycle only: a churning start-up with the first
// goal at 4 MB carves about 4 MB, and the default still collects it before 3 MB.
fn test_the_first_goal_bounds_a_churning_start_up() {
	if os.getenv('VGC_GOAL_CHILD') != '' {
		return
	}
	set := start_up('VGC_FIRST_GOAL_KB=4096 ', 8, false)
	dflt := start_up('', 8, false)
	println('vgc_first_goal: 8 MB churned at start-up — carved ${set.carved:.3f} MB with the first goal at 4 MB, ${dflt.carved:.3f} MB at the default')
	assert set.kept == 1 && dflt.kept == 1
	assert set.carved >= 3.5, 'with the first goal at 4 MB the churn carved only ${set.carved:.3f} MB'
	assert dflt.carved < 3.0, 'the default first goal let the churn carve ${dflt.carved:.3f} MB (bar 3 MB)'
}
