// vgc_young_cards_test.v — the old generation's card barrier (cx-home/v#56
// step 1, `-gc e`; the regime's doc at vgc_young_mode in
// vlib/builtin/vgc_d_vgc.c.v). Under VGC_YOUNG=1, from the first cycle on,
// every pointer store into a heap object sets the card of the page it lands
// on, in the object's arena's own table, by every path a pointer takes into
// an object (young/cards.v: a field, a nested value's field, an array buffer,
// a fixed array, a push into an old buffer and one that regrows, a map, a
// store through a pointer, a statement whose right-hand side collects), and
// the gate widens over an arena mapped between two stops at the next stop; a
// full cycle clears every card and reports them (VGC_GCTRACE=2 `young
// cards=`). Unset, the regime is off: no card is set and no line printed.
// The permanent generation runs on the same cards: permanent/perm_gen.v keeps
// every record under VGC_YOUNG=1 (every regime; the verifier counts no miss).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_young_cards_test.v
module main

import os

fn build(name string, extra string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(),
		'vgc_young_${os.getpid()}_${os.file_name(name).all_before('.')}${extra.replace(' ', '_').replace('-', '')}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc ${extra} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn dirty_of(out string, name string) int {
	line := out.split_into_lines().filter(it.starts_with('check=${name} '))
	assert line.len == 1, 'check ${name} in:\n${out}'
	return line[0].all_after('dirty=').int()
}

const stores = ['a-field', 'b-nested', 'c-array', 'd-fixed', 'e-push-buffer', 'e-push-regrow',
	'g-pointer', 'h-mid-statement', 'i-arena']
const cleans = ['after-collect', 'stack', 'a-cleared', 'i-arena-cleared']

fn test_every_store_into_an_old_object_sets_its_pages_card() {
	exe := build('young/cards.v', '')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_GCTRACE=2 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains('done hold=9 '), r.output
	for name in stores {
		assert dirty_of(r.output, name) == 1, '${name} set no card:\n${r.output}'
	}
	for name in cleans {
		assert dirty_of(r.output, name) == 0, '${name} reads dirty:\n${r.output}'
	}
	// (f) the map's value buffer: the store set a card the cycle had cleared
	c0 := r.output.all_after('cards_after_collect=').int()
	c1 := r.output.all_after('cards_after_store=').int()
	assert c1 > c0, 'the map store set no card (${c0} -> ${c1}):\n${r.output}'
	// the full cycles read and cleared the cards they found
	lines := r.output.split_into_lines().filter(it.contains('] young cards='))
	assert lines.len > 0, r.output
	assert lines.any(it.all_after('cards=').int() > 0), 'no cycle found a card:\n${r.output}'
}

fn test_the_regime_is_off_by_default() {
	exe := build('young/cards.v', '')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_GCTRACE=2 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains('done hold=9 '), r.output
	for name in stores {
		assert dirty_of(r.output, name) == 0, '${name} set a card with the regime off:\n${r.output}'
	}
	for name in cleans {
		assert dirty_of(r.output, name) == 0, '${name} reads dirty:\n${r.output}'
	}
	assert r.output.all_after('cards_after_store=').int() == 0, r.output
	assert !r.output.contains('] young cards='), r.output
}

fn test_the_permanent_generation_keeps_every_record_on_the_cards() {
	exe := build('permanent/perm_gen.v', '')
	defer {
		os.rm(exe) or {}
	}
	for cm in ['', 'VGC_CM=1 ', 'VGC_CM=0 '] {
		r := os.execute('${cm}VGC_YOUNG=1 VGC_GCTRACE=2 T=4 STEPS=10000 ${os.quoted_path(exe)}')
		assert r.exit_code == 0, '${cm}T=4: ${r.output}'
		assert r.output.contains(' bad=0'), '${cm}T=4: ${r.output}'
		assert r.output.contains('promoted=1'), '${cm}T=4: no promotion in ${r.output}'
		assert r.output.contains('] young cards='), '${cm}T=4: ${r.output}'
	}
}

fn test_the_verifier_counts_no_miss_on_the_cards() {
	exe := build('permanent/perm_gen.v', '-d vgc_cm_verify')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_CM=1 VGC_GCTRACE=2 T=4 STEPS=20000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains(' bad=0'), r.output
	lines := r.output.split_into_lines().filter(it.contains('] perm spans='))
	assert lines.len > 0, r.output
	assert lines.last().contains(' missed=0 '), lines.last()
}
