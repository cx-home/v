// vgc_inherited_regs_test.v — cx-home/v#90: a callee-saved register the process start left in
// main's thread is spilled by every collection (vgc_run_gc_spilled's setjmp) and scanned as a
// root. On darwin x86-64 dyld leaves r13 naming a page it freed; in about one run in eight the
// collector's first large span was carved there and vgc_perm_test's dropped transient
// (9,375 KB) stayed live for the life of the process. No such register may name the heap, or
// free address space a later carve could take (inherited_regs/inherited.v). 64 runs: the
// address layout differs every run, and dyld's r13 named such a page in 5 of 40 runs on
// ardec-dev3 (0 of 64 red in a row by chance: 0.875^64, about 2e-4).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_inherited_regs_test.v
module main

import os

fn test_no_inherited_register_names_the_heap_or_free_address_space() {
	src := os.join_path(@DIR, 'inherited_regs', 'inherited.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_inherited_regs_${os.getpid()}')
	b :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b.exit_code == 0, b.output
	defer {
		os.rm(exe) or {}
	}
	for round in 0 .. 64 {
		r := os.execute(os.quoted_path(exe))
		assert r.exit_code == 0, 'round ${round}: ${r.output}'
		assert r.output.contains('inherited n='), 'round ${round}: ${r.output}'
		assert r.output.contains(' hazards=0'), 'round ${round}: an inherited register names the heap or free address space\n${r.output}'
	}
}
