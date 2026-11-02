// vgc_wb_noscan_test.v — the builtin bulk mutators call the card barrier only
// for a buffer that can hold pointers (cx-home/v#56): array.v's push,
// push_many, set, set_unsafe, insert, clone and the grow copy each dirtied the
// buffer's page (vgc_wb_store) before every copy, a `.noscan_data` buffer
// included — a byte pushed into a []u8 under the young regime paid the
// barrier's load, range test and card read per element, and the collector
// never scans that buffer. Now a no-scan buffer takes no barrier call
// (uses_noscan_data, set at the array's creation for an element type without
// pointers and kept across growth, clones and slices), and a buffer that can
// hold pointers takes it as before. young/noscan.v: under VGC_YOUNG=1 after
// the first cycle, every store into an old []u8 leaves its page's card clean
// and a pointer pushed into an old []&Node sets its card.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_wb_noscan_test.v
module main

import os

fn build(name string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(), 'vgc_wb_noscan_${os.getpid()}')
	r := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn dirty_of(out string, name string) int {
	line := out.split_into_lines().filter(it.starts_with('check=${name} '))
	assert line.len == 1, 'check ${name} in:\n${out}'
	return line[0].all_after('dirty=').int()
}

const cleans = ['after-collect', 'u8-push', 'u8-set', 'u8-push-many', 'u8-insert', 'u8-grow']

fn test_a_store_into_a_no_scan_buffer_sets_no_card_and_a_pointer_push_does() {
	exe := build('young/noscan.v')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains('noscan=true ptrs_noscan=false'), r.output
	assert r.output.contains('done sum=11 v=1'), r.output
	for name in cleans {
		assert dirty_of(r.output, name) == 0, '${name} set a card on a no-scan buffer:\n${r.output}'
	}
	assert dirty_of(r.output, 'ptr-push') == 1, 'the pointer push set no card:\n${r.output}'
}
