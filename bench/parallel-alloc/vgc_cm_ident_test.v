// vgc_cm_ident_test.v — https://github.com/cx-home/v/issues/83: under the concurrent
// mark (the `-gc e` default; VGC_CM=1 makes every cycle concurrent, the young
// generation stays off) a record moved through a store whose target is an
// identifier that C reaches through a pointer stays whole: a `mut` parameter of a
// struct type (`*s = v` into an old heap array's element) and an auto-heap local
// (`box->r = v` into its heap box) (concurrent_barrier/cm_ident.v). Before the
// codegen gate on those stores (gen_cm_write_barrier's Ident case) MODE=mut lost
// records in 6 of 6 runs on the pin e9c643f6db (bad=20..210 at T=8 STEPS=80000), and
// this test (eight MODE=mut runs) failed 5 of 5 times there.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_cm_ident_test.v
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'concurrent_barrier', 'cm_ident.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_cm_ident_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_a_store_through_an_identifiers_pointer_keeps_the_record() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for mode in ['mut', 'mut', 'mut', 'mut', 'mut', 'mut', 'mut', 'mut', 'heap'] {
		r := os.execute('VGC_CM=1 T=8 STEPS=80000 MODE=${mode} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, 'MODE=${mode}: ${r.output}'
		assert r.output.contains(' bad=0'), 'MODE=${mode}: ${r.output}'
	}
}
