// vgc_wb_chunk_cards_test.v — the card barrier resolves a store's card
// without an arena lookup, in every arena (cx-home/v#56 lever 10;
// vgc_chunk_cards in thirdparty/vgc/vgc_platform.h, cgen's vgc_wb_gate): the
// cards live in tables by 64 MB chunk of the address space, found from the
// stored-into address by one shift, so the generated C's gate reads any
// arena's card inline and vgc_wb_store sets it without vgc_find_arena. Before,
// the gate read the record of ONE arena (the one at the range's low end,
// vgc_wb_hp), so a store into any other arena called vgc_wb_store, which
// resolved the arena out of line (vgc_wb_store_slow -> vgc_find_arena): on
// binary-trees 18 that path was 45 % of the samples in the cx image under the
// young regime, 20 % under the permanent one (measure/bin/collector-epic/w89/profile.md).
// young/chunk_cards.v under VGC_YOUNG=1: 256 MB live over four arenas or
// more, 64 old records each stored into 1,000 times. Red before the lever:
// calls = the stores into every arena but the first (tens of thousands);
// green: calls within 16 of the 64 records' pages, slow=0, bad=0.
module main

import os

fn build(name string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(),
		'vgc_chunk_cards_${os.getpid()}_${os.file_name(name).all_before('.')}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -d vgc_wb_count -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
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

fn test_a_store_into_any_arena_finds_its_card_inline() {
	exe := build('young/chunk_cards.v')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 LIVE_MB=256 RECS=64 REPEAT=1000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	d := done_line(r.output)
	println('vgc_wb_chunk_cards: ${d}')
	assert d.contains(' bad=0 '), r.output
	arenas := field(d, 'arenas')
	assert arenas >= 4, 'the live set holds ${arenas} arenas: too few to tell one arena\'s record from every arena\'s cards\n${r.output}'
	calls := field(d, 'calls')
	slow := field(d, 'slow')
	// 64 records, 1,000 stores each: the first store into a record's page
	// calls (its card unset), the rest read the set card in the gate
	assert calls <= 64 + 16, 'the stores called the barrier ${calls} times over 64 records: the gate reads one arena\'s cards, not every arena\'s\n${r.output}'
	assert slow == 0, '${slow} calls resolved their arena out of line\n${r.output}'
}
