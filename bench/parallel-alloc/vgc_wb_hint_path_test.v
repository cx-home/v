// vgc_wb_hint_path_test.v — the card barrier's own fast path reads the hint
// record (cx-home/v#56 lever 6; vgc_wb_store's doc in
// vlib/builtin/vgc_gc_d_vgc.c.v): a vgc_wb_store call for a store into the
// hint arena resolves on the record (vgc_wb_hp: base, size, cards) with one
// plain load and one range test, and never reaches vgc_wb_store_slow.
// permanent/hint_path.v pushes 100,000 young pointers into a permanent
// []&Rec through array.push (the bulk mutators' path, which calls the
// barrier on every store): under -d vgc_wb_count the calls are at least
// 100,000, the slow calls are 0, the buffer's card is set, and the record
// pushed last survives two collections held by the permanent buffer alone.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_wb_hint_path_test.v
module main

import os

fn build(name string, extra string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(), 'vgc_wb_hint_path_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc ${extra} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn field(out string, name string) string {
	line := out.split_into_lines().filter(it.starts_with('calls='))
	assert line.len == 1, 'the calls line in:\n${out}'
	w := line[0].split(' ').filter(it.starts_with('${name}='))
	assert w.len == 1, '${name} in: ${line[0]}'
	return w[0].all_after('=')
}

fn test_a_bulk_store_into_the_hint_arena_never_takes_the_slow_path() {
	exe := build('permanent/hint_path.v', '-d vgc_wb_count')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute(os.quoted_path(exe))
	assert r.exit_code == 0, r.output
	calls := field(r.output, 'calls').int()
	assert calls >= 100000, 'the pushes did not call the barrier on every store: ${r.output}'
	slow := field(r.output, 'slow').int()
	assert slow == 0, 'a store into the hint arena took the slow path: ${r.output}'
	assert field(r.output, 'dirty') == 'true', 'the buffer page has no card: ${r.output}'
	assert field(r.output, 'bad') == '0', 'a record held by the permanent buffer was lost: ${r.output}'
}
