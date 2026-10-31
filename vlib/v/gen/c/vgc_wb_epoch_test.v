// vgc_wb_epoch_test.v — cx-home/v#56 lever 3: a heap pointer store's second
// write-barrier gate (the one that re-dirties after a stop cleared what the
// first gate set) is made only when a stop ran between the first gate and
// the store: the generated statement reads the stop count before its first
// gate and makes the second gate under `if (vgc_wb_epoch_moved(<count>))`.
// A store into a local pointer variable carries neither.
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

fn test_the_second_gate_is_made_only_after_a_stop() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'epoch.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_epoch_${os.getpid()}')
	res :=
		os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)}.c ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file('${out}.c')!
	os.rm('${out}.c') or {}
	assert c.contains('extern size_t vgc_wb_epoch;'), 'the stop count is not declared'
	assert c.contains('static inline size_t vgc_wb_epoch_now(void)'), 'no vgc_wb_epoch_now'
	assert c.contains('static inline int vgc_wb_epoch_moved(size_t e)'), 'no vgc_wb_epoch_moved'
	link := fn_body(c, 'main__link')
	assert link.len > 0, 'main__link not emitted'
	// two stores (n.next, n.name): a first gate and a conditional second gate each
	assert link.count('vgc_wb_gate') == 4, 'main__link has not 4 gates:\n${link}'
	assert link.count('= vgc_wb_epoch_now();') == 2, 'main__link reads the stop count not twice:\n${link}'
	assert link.count('if (vgc_wb_epoch_moved(') == 2, 'main__link tests the stop count not twice:\n${link}'
	// the order per statement: the count read, the first gate, the store, the test, the second gate
	lines := link.split_into_lines().map(it.trim_space())
	read := lines.index(lines.filter(it.contains('vgc_wb_epoch_now()'))[0])
	first := lines.index(lines.filter(it.starts_with('vgc_wb_gate('))[0])
	store := lines.index(lines.filter(it.contains('->next = '))[0])
	moved := lines.index(lines.filter(it.starts_with('if (vgc_wb_epoch_moved('))[0])
	assert read < first, 'the count is read after the first gate:\n${link}'
	assert first < store, 'the first gate follows the store:\n${link}'
	assert store < moved, 'the test precedes the store:\n${link}'
	assert lines[moved + 1].starts_with('vgc_wb_gate('), 'no second gate under the test:\n${link}'
	// the same name is read and tested
	name := lines[read].all_before(' = vgc_wb_epoch_now').all_after_last(' ')
	assert lines[moved] == 'if (vgc_wb_epoch_moved(${name})) {', 'the test reads another count:\n${link}'
	cnt := fn_body(c, 'main__count')
	assert cnt.len > 0, 'main__count not emitted'
	assert !cnt.contains('vgc_wb_gate') && !cnt.contains('vgc_wb_epoch'), 'a local pointer store is gated:\n${cnt}'
	built :=
		os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert built.exit_code == 0, built.output
	run := os.execute(os.quoted_path(out))
	os.rm(out) or {}
	assert run.exit_code == 0, run.output
	assert run.output.trim_space() == '2001\n2000\nn1999', run.output
}
