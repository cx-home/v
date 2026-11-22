// vgc_safe_region_callee_saved_test.v (cx-home/v#88) — an object whose only reference is a callee-saved register
// of a thread waiting in a GC-safe region survives the collections that run while it waits.
//
// A thread in a GC-safe region (a thread join, a semaphore wait, a socket wait) is not stopped:
// the collector scans the stack prefix it recorded at gc_safe_region_enter and the registers it
// spilled there. The spill (vgc_safe_enter_spill) is a function of its own; compiled with
// optimization it saves the caller's callee-saved registers in its frame and loads its arguments
// into them before its setjmp, so the snapshot holds the spill's own values, and the caller's
// values sit only in the spill's frame, which dies when enter returns and which the blocking
// call's frames overwrite. A caller that keeps a heap pointer in such a register across the
// blocking call (a compiled loop joining threads and collecting their results) has it scanned
// nowhere: the object is freed and handed out again while the caller still uses it.
//
// Shape (safe_region_regs/hold.v, hold.h): an asm block holds a 256-byte object's address only in
// x19 (arm64) / rbx (x86-64), enters the region, writes a 4 KB frame where enter's frames were,
// waits while another thread runs two full collections, leaves the region. The object must still
// be allocated. Control: the same with nothing holding the address; its object must be freed.
// The program is built with -O2 (the optimization the cx executables use) and with -prod.
// Red on 1af95505d7 at -O2 on macOS arm64: held_freed=20 of 20 (control_freed=20); at -O0, 0.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_safe_region_callee_saved_test.v
module main

import os

fn build(flags string) string {
	src := os.join_path(@DIR, 'safe_region_regs', 'hold.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_srr_hold_${os.getpid()}_${flags.len}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc ${flags} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn run(flags string) {
	exe := build(flags)
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('ROUNDS=20 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines().filter(it.starts_with('done '))
	assert lines.len == 1, r.output
	println('vgc_safe_region_callee_saved ${flags}: ${lines[0]}')
	if lines[0].starts_with('done covered=0 ') {
		eprintln('  (this platform has no callee-saved holder; nothing to check)')
		return
	}
	assert lines[0].contains(' control_freed=20 '), 'the control kept its objects: the measure cannot see a freed object: ${lines[0]}'
	assert lines[0].contains(' held_freed=0 '), 'objects held only in a callee-saved register across a GC-safe region were freed while live: ${lines[0]}'
}

fn test_an_object_held_in_a_callee_saved_register_across_a_safe_region_survives_at_o2() {
	run('-cflags -O2')
}

fn test_an_object_held_in_a_callee_saved_register_across_a_safe_region_survives_under_prod() {
	run('-prod')
}
