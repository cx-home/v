// vgc_wb_ptr_index_test.v — https://github.com/cx-home/v/issues/93: `p[i] = v`
// through a raw pointer (p a `&T`, T pointer-bearing) is a heap store as surely as
// `a[i] = v` into an array's buffer, and under -gc e it carries the same gate on
// the pointer, before and after the store (assign.v gen_cm_write_barrier). Before,
// the IndexExpr arm gated array, fixed-array and map element stores only, so the
// store went unrecorded: under the young regime a young object stored into an old
// buffer was swept by the next minor (bench/parallel-alloc/vgc_young_ptr_index_test.v).
// A pointer-free element (`&int`) carries no gate.
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

fn test_a_pointer_index_store_of_a_pointer_bearing_value_gates_the_pointer() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'ptr_index.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_ptr_index_${os.getpid()}.c')
	res := os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file(out)!
	os.rm(out) or {}
	ptr := fn_body(c, 'main__store_ptr')
	assert ptr.len > 0, 'main.store_ptr not emitted'
	// the gate before the store and the second gate after it
	assert ptr.count('vgc_wb_gate((voidptr)(p));') == 1, 'main.store_ptr:\n${ptr}'
	assert ptr.count('vgc_wb_gate_again((voidptr)(p));') == 1, 'main.store_ptr:\n${ptr}'
	cell := fn_body(c, 'main__store_cell')
	assert cell.count('vgc_wb_gate((voidptr)(p));') == 1, 'main.store_cell:\n${cell}'
	ints := fn_body(c, 'main__store_ints')
	assert ints.len > 0, 'main.store_ints not emitted'
	assert !ints.contains('vgc_wb_gate'), 'a pointer-free element is gated:\n${ints}'
}
