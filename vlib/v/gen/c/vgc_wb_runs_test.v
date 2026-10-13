// vgc_wb_runs_test.v — cx-private#1924 cut 3: a statement's after barrier and
// the next statement's before barrier on the same base, adjacent in the text,
// are one call (gen_cm_write_barrier's wb_gate). testdata/vgc_wb/wb_runs.vv's
// link() stores three fields through p, then one inside an `if`, then one
// after it: 10 gates before (two per store), 8 now — the run of three shares
// two, and the brace around the `if` keeps both of its neighbours' gates.
import os

const vexe = @VEXE

fn test_a_run_of_stores_through_one_base_shares_its_gates() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'wb_runs.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_runs_${os.getpid()}.c')
	res := os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file(out)!
	os.rm(out) or {}
	body := c.all_after('VV_LOC void main__link(main__Node* p, main__Node* q, main__Node* r) {').all_before('\n}\n')
	gates := body.count('vgc_wb_gate((voidptr)(p));')
	println('vgc_wb_runs: ${gates} gates in link()')
	assert gates == 8, 'link() has ${gates} gates, expected 8 (10 before the run sharing):\n${body}'
	// every store still has a gate right before and right after it
	lines := body.split_into_lines().map(it.trim_space()).filter(it != '')
	for i, l in lines {
		if l.starts_with('p->') {
			assert i > 0 && lines[i - 1] == 'vgc_wb_gate((voidptr)(p));', 'no gate before ${l}'
			assert i + 1 < lines.len && lines[i + 1] == 'vgc_wb_gate((voidptr)(p));', 'no gate after ${l}'
		}
	}
}
