// vgc_first_goal_test.v — a declared start-up runs no collection under the
// first goal for one thread (cx-home/v#76, beside cx-private#2068 and
// cx-private#2051).
//
// Shape: a child declares its start-up (gc_startup_begin), builds 3 MB of live
// 48-byte nodes — a cx built program decodes its modules' heads and builds its
// scopes before its first explicit work (n-body built --native: 2.8 MB
// allocated) — closes it (gc_startup_done) and reads gc_cycles(): none ran
// under the default environment. The same child with the start-up undeclared
// runs the clamp's first cycle at 1 MB (cx-home/v#14's rule, kept: a program
// that says nothing pays nothing new), and a declared start-up under
// VGC_FIRST_GOAL_MB=1 still collects — the default is the goal's work.
//
// Run: ./v test bench/parallel-alloc/vgc_first_goal_test.v
module main

import os

struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

const start_live_bytes = 3 * 1024 * 1024
const node_bytes = 48

fn child(declared bool) {
	if declared {
		gc_startup_begin()
	}
	mut head := &Node(unsafe { nil })
	for i in 0 .. start_live_bytes / node_bytes {
		mut n := &Node{
			next: head
		}
		n.pad[0] = u64(i)
		head = n
	}
	if declared {
		gc_startup_done()
	}
	cycles := gc_cycles()
	mut kept := 0
	for n := head; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('CYCLES=${cycles} kept=${kept} carved=${gc_memory_use()}')
}

fn cycles_of(env string, arm string) u64 {
	r := os.execute('VGC_FIRST_GOAL_CHILD=${arm} ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	for l in r.output.split_into_lines() {
		if l.starts_with('CYCLES=') {
			return l.all_after('CYCLES=').all_before(' ').u64()
		}
	}
	panic(r.output)
}

fn test_a_declared_start_up_of_three_mb_runs_no_cycle() {
	arm := os.getenv('VGC_FIRST_GOAL_CHILD')
	if arm == 'declared' {
		child(true)
		return
	}
	if arm == 'bare' {
		child(false)
		return
	}
	if arm != '' {
		return
	}
	declared := cycles_of('', 'declared')
	bare := cycles_of('', 'bare')
	one_mb := cycles_of('VGC_FIRST_GOAL_MB=1 ', 'declared')
	println('vgc_first_goal: 3 MB live at start — declared ${declared} cycles, undeclared ${bare}, declared under a 1 MB first goal ${one_mb}')
	assert bare > 0, 'an undeclared start-up keeps the clamp\'s first cycle: ${bare} cycles'
	assert one_mb > 0, 'a 1 MB first goal collects a 3 MB start-up: ${one_mb} cycles (the knob is read)'
	assert declared == 0, 'a declared 3 MB start-up was collected under the default first goal: ${declared} cycles'
}
