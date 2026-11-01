// vgc_wb_nursery_gate_test.v — the nursery-region gate (cx-home/v#56 lever
// 7): under the young regime a pointer store into a fresh young record makes
// no vgc_wb_store call — the gate's first test skips a store into the young
// range (the spans carved since the last stop, from the nursery's reserved
// address range) before the hint record and the card are read. young/nursery.v
// chains N fresh records by N-1 stores after a warm batch filled the sweep's
// free slots: under -d vgc_wb_count the calls counted over those stores are
// 0 and no record's page card is set (before the lever every record's init
// store called and set its card, and the chain's stores read it), a store of
// the chain's head into an old record still calls, and the chain survives a
// minor cycle through that old record alone.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_wb_nursery_gate_test.v
module main

import os

fn build(name string, extra string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(), 'vgc_wb_nursery_gate_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc ${extra} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn field(out string, name string) string {
	line := out.split_into_lines().filter(it.starts_with('dirty='))
	assert line.len == 1, 'the dirty line in:\n${out}'
	w := line[0].split(' ').filter(it.starts_with('${name}='))
	assert w.len == 1, '${name} in: ${line[0]}'
	return w[0].all_after('=')
}

fn test_a_store_into_a_fresh_young_record_makes_no_call_and_sets_no_card() {
	exe := build('young/nursery.v', '-d vgc_wb_count')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert field(r.output, 'setup_minors') == '0', 'a cycle ran between the fresh records and the stores: ${r.output}'
	fresh_recs := field(r.output, 'fresh')
	assert fresh_recs.all_before('/') == fresh_recs.all_after('/'), 'not every record came from a fresh span of the nursery: ${r.output}'
	dirty := field(r.output, 'dirty')
	assert dirty.all_before('/') == '0', 'a fresh young record\'s page card is set after the stores (${dirty} records on a set card): ${r.output}'
	calls := field(r.output, 'calls')
	fresh := calls.all_before('/').int()
	assert fresh == 0, 'a store into a fresh young record called the barrier (${fresh} calls over the chain): ${r.output}'
	assert field(r.output, 'old_card') == 'true', 'the store into the old record set no card: ${r.output}'
	assert field(r.output, 'minors').int() >= 1, 'no minor cycle ran: ${r.output}'
	assert field(r.output, 'bad') == '0', 'a record of the chain was reclaimed or rewritten: ${r.output}'
	chain := field(r.output, 'chain')
	assert chain.all_before('/') == chain.all_after('/'), 'the chain is short after the minor cycle: ${r.output}'
}
