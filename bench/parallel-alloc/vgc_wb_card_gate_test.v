// vgc_wb_card_gate_test.v — the generated C's write-barrier gate reads the
// card itself (cx-home/v#56 lever 5; the gate's doc at vgc_wb_hints in
// vlib/builtin/vgc_d_vgc.c.v): a pointer store the range test let through,
// into the hint arena, whose page's card is set makes no vgc_wb_store call.
// permanent/card_gate.v makes two records permanent and stores 100,000
// young pointers into each with no stop between the stores: under
// -d vgc_wb_count the calls counted are one per record's page (the old gate
// called the barrier on every store: 200,000), both cards are set, and the
// record stored last survives two collections held by the permanent objects
// alone.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_wb_card_gate_test.v
module main

import os

fn build(name string, extra string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(), 'vgc_wb_card_gate_${os.getpid()}')
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

fn test_a_store_into_a_page_whose_card_is_set_makes_no_call() {
	exe := build('permanent/card_gate.v', '-d vgc_wb_count')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute(os.quoted_path(exe))
	assert r.exit_code == 0, r.output
	calls := field(r.output, 'calls').int()
	assert calls >= 2, 'the first store into each record made no call: ${r.output}'
	assert calls <= 2, 'the stores into a page whose card is set called the barrier: ${r.output}'
	assert field(r.output, 'dirty') == 'true/true', 'a card is not set: ${r.output}'
	assert field(r.output, 'bad') == '0', 'a record the permanent object holds was reclaimed: ${r.output}'
}
