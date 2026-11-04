// vgc_minor_cards_walk_test.v — a minor cycle's card scan is sized by the
// dirty cards, not by the heap's span count (cx-home/v#56 lever 9;
// vgc_minor_cards in vlib/builtin/vgc_gc_d_vgc.c.v): under VGC_YOUNG=1 a
// minor over a 96 MB live set (some 12,000 spans) with ten stores into old
// records reads the cards of the spans those stores dirtied — a walk over
// the arenas' card tables, a byte a page, eight pages a word — and no other
// span's. Before, the scan asked every span in use for its cards
// (vgc_cards_take: an arena lookup and a page loop a span, 33,000–52,000
// spans a minor on binary-trees 18, 624 minors a run: measure/collector-epic-85's
// F trace), so a minor's stop grew with the heap, not with its dirty set.
// young/cards_walk.v: red before the lever (visited = every span in use);
// green: visited and card_spans within 16 of the stores, every stored
// record kept.
module main

import os

fn build(name string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(),
		'vgc_cards_walk_${os.getpid()}_${os.file_name(name).all_before('.')}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn done_line(out string) string {
	lines := out.split_into_lines().filter(it.starts_with('done bad='))
	assert lines.len == 1, out
	return lines[0]
}

fn field(d string, name string) int {
	return d.all_after(' ${name}=').all_before(' ').int()
}

fn test_a_minor_cycle_reads_the_dirty_cards_and_no_other_span() {
	exe := build('young/cards_walk.v')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 VGC_YOUNG_LIVE_MB=0 LIVE_MB=96 STORES=10 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	d := done_line(r.output)
	println('vgc_minor_cards_walk: ${d}')
	assert d.contains(' bad=0 '), r.output
	assert field(d, 'minors') >= 1, 'no minor cycle ran over the young garbage\n${r.output}'
	nspans := field(d, 'nspans')
	assert nspans >= 10000, 'the live set holds ${nspans} spans: too small to tell a walk over the heap from one over the cards\n${r.output}'
	visited := field(d, 'visited')
	spans := field(d, 'card_spans')
	// the ten stores dirtied ten cards (a few more from the runtime's own
	// stores); the minor read those spans' cards and no other span's
	assert spans <= 10 + 16, 'the minor found cards in ${spans} spans over ten stores\n${r.output}'
	assert visited <= 10 + 16, 'the minor read the cards of ${visited} spans over ${nspans} in use: a walk over the heap, not over the dirty cards\n${r.output}'
}
