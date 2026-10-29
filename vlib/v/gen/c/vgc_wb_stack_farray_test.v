// vgc_wb_stack_farray_test.v — cx-private#1924 cut 2: a store into a fixed
// array that is a local of the function (`buf[i] = v`, `mut buf := [4]T{}`)
// writes the C stack, a root the collector scans at every stop, never a heap
// span: the gate there finds nothing to dirty, so none is emitted. A fixed
// array a mut parameter points at, or one inline in a struct reached through
// a pointer, can be heap memory and keeps its gates (the controls).
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

fn test_a_local_fixed_array_store_carries_no_gate() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'stack_farray.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_stack_farray_${os.getpid()}')
	res := os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)}.c ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file('${out}.c')!
	os.rm('${out}.c') or {}
	local := fn_body(c, 'main__fill_local')
	assert local.len > 0, 'main__fill_local not emitted'
	assert local.contains('buf['), 'main__fill_local has no store into buf:\n${local}'
	assert !local.contains('vgc_wb_gate'), 'a local fixed array store is still gated:\n${local}'
	param := fn_body(c, 'main__fill_param')
	assert param.count('vgc_wb_gate') == 2, 'the mut parameter store lost its gates:\n${param}'
	field := fn_body(c, 'main__fill_field')
	assert field.count('vgc_wb_gate') == 2, 'the field store lost its gates:\n${field}'
	built := os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert built.exit_code == 0, built.output
	run := os.execute(os.quoted_path(out))
	os.rm(out) or {}
	assert run.exit_code == 0, run.output
	assert run.output.trim_space() == '12\ncdef', run.output
}
