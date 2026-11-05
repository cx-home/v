// vgc_wb_card_test.v — cx-home/v#56 lever 5: the generated C's write-barrier
// gate reads the card itself; lever 10: from the cards by chunk. The headers
// carry builtin's table of chunk tables `vgc_wb_cards` (vgc_chunk_cards in
// thirdparty/vgc/vgc_platform.h), the page shift as builtin's vgc_page_shift,
// the chunk shift and count as the address map's (VGC_ADDR_SHIFT,
// VGC_ADDR_MAP_SIZE), and the gate reads the card before it calls
// vgc_wb_store. The program of
// vgc_wb_epoch_test.v builds and runs as before.
import os

const vexe = @VEXE

fn test_the_gate_reads_the_card_before_the_call() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'epoch.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_card_${os.getpid()}')
	res :=
		os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)}.c ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file('${out}.c')!
	os.rm('${out}.c') or {}
	assert c.contains('extern void* vgc_wb_cards;'), 'the chunk card tables are not declared'
	// the page shift the gate uses is builtin's
	builtin := os.read_file(os.join_path(os.dir(vexe), 'vlib', 'builtin', 'vgc_d_vgc.c.v'))!
	shift := builtin.split_into_lines().filter(it.starts_with('const vgc_page_shift = '))
	assert shift.len == 1, 'vgc_page_shift in vlib/builtin/vgc_d_vgc.c.v'
	n := shift[0].all_after('= ').all_before(' ').int()
	assert c.contains('#define VGC_WB_PAGE_SHIFT ${n}\n'), 'the gate\'s page shift is not vgc_page_shift (${n})'
	gate := c.split_into_lines().filter(it.starts_with('static inline void vgc_wb_gate(void* p)'))
	assert gate.len == 1, 'the gate is not emitted once'
	assert gate[0].contains('(size_t)(uintptr_t)p - vgc_wb_lo < vgc_wb_len'), 'the range test is gone:\n${gate[0]}'
	// lever 14: the card read runs out of line, in vgc_wb_gate_card
	card_fn := c.split_into_lines().filter(it.starts_with('static VGC_WB_NOINLINE void vgc_wb_gate_card(void* p)'))
	assert card_fn.len == 1, 'vgc_wb_gate_card is not emitted once'
	g := card_fn[0]
	card := g.index('t[ci][((size_t)(uintptr_t)p >> VGC_WB_PAGE_SHIFT) & VGC_WB_CHUNK_MASK] != 0) return;') or {
		-1
	}
	call := g.index('vgc_wb_store(p);') or { -1 }
	assert card >= 0, 'the gate does not read the card:\n${g}'
	assert call > card, 'the call is not after the card read:\n${g}'
	assert g.contains('t != 0 && ci < VGC_WB_CHUNKS && t[ci] != 0 &&'), 'the card read is not under the chunk table\'s bounds:\n${g}'
	// the chunk shift is the address map's (VGC_ADDR_SHIFT, vgc_platform.h)
	plat := os.read_file(os.join_path(os.dir(vexe), 'thirdparty', 'vgc', 'vgc_platform.h'))!
	assert plat.contains('#define VGC_ADDR_SHIFT 26 '), 'VGC_ADDR_SHIFT in vgc_platform.h'
	assert c.contains('#define VGC_WB_CHUNK_SHIFT 26\n'), "the gate's chunk shift is not VGC_ADDR_SHIFT"
	assert plat.contains('#define VGC_ADDR_MAP_SIZE 65536 '), 'VGC_ADDR_MAP_SIZE in vgc_platform.h'
	assert c.contains('#define VGC_WB_CHUNKS 65536\n'), "the gate's chunk count is not VGC_ADDR_MAP_SIZE"
	assert c.contains('#define VGC_WB_CHUNK_MASK ${(1 << (26 - n)) - 1}\n'), "the gate's card mask is not a chunk's cards less one"
	built :=
		os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert built.exit_code == 0, built.output
	run := os.execute(os.quoted_path(out))
	os.rm(out) or {}
	assert run.exit_code == 0, run.output
	assert run.output.trim_space() == '2001\n2000\nn1999', run.output
}
