// vgc_wb_card_test.v — cx-home/v#56 lever 5: the generated C's write-barrier
// gate reads the card itself. The headers carry the hint record's C shape
// (`struct vgc_wb_hint_t`: base, size, cards — VGC_WbHint's fields in
// vlib/builtin/vgc_d_vgc.c.v, in that order), builtin's record pointer
// `vgc_wb_hp`, the page shift as builtin's vgc_page_shift, and vgc_wb_gate
// reads the card before it calls vgc_wb_store. The program of
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
	assert c.contains('struct vgc_wb_hint_t { size_t base; size_t size; unsigned char* cards; };'), 'the hint record is not declared'
	assert c.contains('extern void* vgc_wb_hp;'), 'the record pointer is not declared'
	// the page shift the gate uses is builtin's
	builtin := os.read_file(os.join_path(os.dir(vexe), 'vlib', 'builtin', 'vgc_d_vgc.c.v'))!
	shift := builtin.split_into_lines().filter(it.starts_with('const vgc_page_shift = '))
	assert shift.len == 1, 'vgc_page_shift in vlib/builtin/vgc_d_vgc.c.v'
	n := shift[0].all_after('= ').all_before(' ').int()
	assert c.contains('#define VGC_WB_PAGE_SHIFT ${n}\n'), 'the gate\'s page shift is not vgc_page_shift (${n})'
	gate := c.split_into_lines().filter(it.starts_with('static inline void vgc_wb_gate(void* p)'))
	assert gate.len == 1, 'the gate is not emitted once'
	g := gate[0]
	assert g.contains('(size_t)(uintptr_t)p - vgc_wb_lo < vgc_wb_len'), 'the range test is gone:\n${g}'
	card := g.index('h->cards[((size_t)(uintptr_t)p - h->base) >> VGC_WB_PAGE_SHIFT] != 0) return;') or { -1 }
	call := g.index('vgc_wb_store(p);') or { -1 }
	assert card >= 0, 'the gate does not read the card:\n${g}'
	assert call > card, 'the call is not after the card read:\n${g}'
	assert g.contains('h != 0 && (size_t)(uintptr_t)p - h->base < h->size &&'), 'the card read is not under the hint\'s range:\n${g}'
	built :=
		os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert built.exit_code == 0, built.output
	run := os.execute(os.quoted_path(out))
	os.rm(out) or {}
	assert run.exit_code == 0, run.output
	assert run.output.trim_space() == '2001\n2000\nn1999', run.output
}
