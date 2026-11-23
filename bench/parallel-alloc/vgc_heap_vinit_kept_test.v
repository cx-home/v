// vgc_heap_vinit_kept_test.v — the objects builtin's consts allocate stay in the
// collector's books.
//
// builtin's consts are _vinit's first statements, and they allocate
// (`error_sentinel` boxes a MessageError). The collector's own globals came
// after them as _vinit statements of their own: `vgc_heap = VGC_Heap{}` was a
// memset of the whole heap record and `vgc_arena_lo = usize(0)` reset the
// arena range, so the arena and the spans builtin's consts had carved fell out
// of the heap's books while their pages stayed mapped (in a cx program built
// --native: 6 spans, 49,152 B carved, 3,177 B allocated). cgen now gives such a
// global (a zero-valued struct, a C constant) its value in its C definition and
// emits no _vinit statement for it.
//
// vinit_kept/kept.v is the fixture: main asks the collector which arena holds
// error_sentinel's object and whether a span owns it. Red on 394a12489 (the
// cgen before the fix): `arena=-1 span=no carved=8192`.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_heap_vinit_kept_test.v
module main

import os

fn test_builtin_consts_objects_stay_in_the_heaps_books() {
	src := os.join_path(@DIR, 'vinit_kept', 'kept.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_vinit_kept_${os.getpid()}')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('${os.quoted_path(@VEXE)} -gc e -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	run := os.execute(os.quoted_path(exe))
	assert run.exit_code == 0, 'exit ${run.exit_code}: ${run.output}'
	out := run.output.trim_space()
	println(out)
	assert out.starts_with('arena=0 span=yes '), out
}
