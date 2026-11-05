// vgc_wb_gate_size_test.v — cx-home/v#56 lever 14: the write-barrier gate a
// heap pointer store carries inline is the two range tests and one call. The
// card read (levers 5 and 10) runs out of line in vgc_wb_gate_card, reached
// only when a store lands in the gate's range (a concurrent cycle's middle, or
// the young regime); the second gate a store statement makes after a stop
// (lever 3) is a call to vgc_wb_gate_again. Every inline copy of the card read
// and of the second gate grew the program text of every store site (cx: 609 KB
// of __text, about 0.2 MB of resident memory in a program that does nothing),
// for work that runs only inside a cycle.
import os

const vexe = @VEXE

fn fn_body(c string, name string) string {
	mut out := []string{}
	mut inside := false
	for l in c.split_into_lines() {
		if !inside {
			inside = l.contains(' ${name}(') && l.trim_space().ends_with('{')
			continue
		}
		if l == '}' {
			break
		}
		out << l
	}
	return out.join('\n')
}

fn test_the_inline_gate_is_the_range_tests_and_one_call() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'epoch.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_gate_size_${os.getpid()}')
	res :=
		os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)}.c ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file('${out}.c')!
	os.rm('${out}.c') or {}
	lines := c.split_into_lines()
	gate := lines.filter(it.starts_with('static inline void vgc_wb_gate(void* p)'))
	assert gate.len == 1, 'the inline gate is not emitted once'
	g := gate[0]
	assert g.contains('(size_t)(uintptr_t)p - vgc_young_lo < vgc_young_len) return;'), 'the young test is gone:\n${g}'
	assert g.contains('(size_t)(uintptr_t)p - vgc_wb_lo < vgc_wb_len)) vgc_wb_gate_card(p);'), 'the range test does not call vgc_wb_gate_card:\n${g}'
	assert !g.contains('vgc_wb_cards') && !g.contains('VGC_WB_PAGE_SHIFT'), 'the inline gate reads the card:\n${g}'
	assert !g.contains('vgc_wb_store'), 'the inline gate calls vgc_wb_store itself:\n${g}'
	// the card read, out of line, before the call
	card := lines.filter(it.contains(' void vgc_wb_gate_card(void* p)'))
	assert card.len == 1, 'vgc_wb_gate_card is not emitted once'
	k := card[0]
	assert k.starts_with('static VGC_WB_NOINLINE void vgc_wb_gate_card(void* p)'), 'vgc_wb_gate_card is not out of line:\n${k}'
	read := k.index('t[ci][((size_t)(uintptr_t)p >> VGC_WB_PAGE_SHIFT) & VGC_WB_CHUNK_MASK] != 0) return;') or {
		-1
	}
	call := k.index('vgc_wb_store(p);') or { -1 }
	assert read >= 0, 'vgc_wb_gate_card does not read the card:\n${k}'
	assert call > read, 'the call is not after the card read:\n${k}'
	assert k.contains('t != 0 && ci < VGC_WB_CHUNKS && t[ci] != 0 &&'), "the card read is not under the chunk table's bounds:\n${k}"
	again := lines.filter(it.starts_with('static VGC_WB_NOINLINE void vgc_wb_gate_again(void* p) { vgc_wb_gate(p); }'))
	assert again.len == 1, 'vgc_wb_gate_again is not emitted once, out of line'
	assert c.contains('#define VGC_WB_NOINLINE __attribute__((noinline, unused))'), 'no VGC_WB_NOINLINE'
	// a store statement: the first gate inline, the second (after a stop) a call
	link := fn_body(c, 'main__link')
	assert link.len > 0, 'main__link not emitted'
	ls := link.split_into_lines().map(it.trim_space())
	assert ls.filter(it.starts_with('vgc_wb_gate((voidptr)')).len == 2, 'main__link has not two first gates:\n${link}'
	assert ls.filter(it.starts_with('vgc_wb_gate_again((voidptr)')).len == 2, 'main__link has not two second gates out of line:\n${link}'
	for i, l in ls {
		if l.starts_with('if (vgc_wb_epoch_moved(') {
			assert ls[i + 1].starts_with('vgc_wb_gate_again('), 'the second gate under the test is not vgc_wb_gate_again:\n${link}'
		}
	}
	built :=
		os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert built.exit_code == 0, built.output
	run := os.execute(os.quoted_path(out))
	os.rm(out) or {}
	assert run.exit_code == 0, run.output
	assert run.output.trim_space() == '2001\n2000\nn1999', run.output
}
