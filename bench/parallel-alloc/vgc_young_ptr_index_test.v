// vgc_young_ptr_index_test.v — the objects stored through a raw pointer index into
// an old buffer survive the minor cycles after the store
// (https://github.com/cx-home/v/issues/93). `unsafe { p[i] = v }`, p a `&T` into an
// array's buffer and T pointer-bearing, carried no write-barrier gate: cgen's
// gen_cm_write_barrier gated an array, fixed-array or map element store and
// nothing else, so under the young regime a young object stored that way into a
// buffer a minor had already marked (old) left no card, and the next minor swept
// it while the buffer still named it. cx's interpreter appends to its node arrays
// that way (cx-core-code compiled_def.v node_push, crun_args_in): fannkuch-redux
// 11 [par 28] under VGC_YOUNG=1 answered a wrong checksum or SIGSEGV'd 9 of 9 runs
// on dev1, and -d vgc_cm_verify counted a missed object at every minor, each held
// by an old buffer. Shape: young/ptr_index.v, 20 rounds; bad = slots whose object
// changed.
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'young', 'ptr_index.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_ptr_index_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_objects_stored_through_a_pointer_index_into_an_old_buffer_survive_the_minors() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for env in ['VGC_YOUNG=1 VGC_NEXT_GC_MB=1', 'VGC_YOUNG=1 VGC_NEXT_GC_MB=1 VGC_YOUNG_MINORS=32'] {
		r := os.execute('${env} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, '${env}: ${r.output}'
		lines := r.output.split_into_lines().filter(it.starts_with('done bad='))
		assert lines.len == 1, r.output
		println('vgc_young_ptr_index ${env}: ${lines[0]}')
		assert !lines[0].contains('minors=0'), 'no minor cycle ran: ${lines[0]}'
		assert lines[0].starts_with('done bad=0 '), lines[0]
	}
}
