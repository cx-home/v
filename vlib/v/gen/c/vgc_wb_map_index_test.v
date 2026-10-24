// vgc_wb_map_index_test.v — cx-core-code#208: `m[k] = v` compiles to
// `*map_get_and_set(&m, &k, &zero) = v`, a store through the pointer into the
// map's value buffer that map_set (which only inserts a new key's zero value)
// never sees. Under -gc e the statement gates the value buffer before and after
// the store, as an array element store gates its buffer (assign.v
// gen_cm_write_barrier); a map whose values hold no pointer carries no gate.
// Without the gate, a value stored into a permanent map (cx-home/v#15) was
// never re-scanned and was swept while the map named it (perm_gen.v path f).
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

fn test_a_map_index_store_gates_the_value_buffer_before_and_after() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'map_index.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_map_index_${os.getpid()}.c')
	res := os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file(out)!
	os.rm(out) or {}
	field := fn_body(c, 'main__store_field')
	assert field.contains('map_get_and_set'), 'the store is no longer a get_and_set store:\n${field}'
	// two statements, a gate before and after each
	assert field.count('key_values.values));') == 4, 'main.store_field:\n${field}'
	local := fn_body(c, 'main__store_local')
	assert local.count('key_values.values));') == 2, 'main.store_local:\n${local}'
	// a `mut` map parameter is a pointer in C
	param := fn_body(c, 'main__store_param')
	assert param.count('(pm)->key_values.values));') == 2, 'main.store_param:\n${param}'
	ints := fn_body(c, 'main__store_ints')
	assert ints.len > 0, 'main.store_ints not emitted'
	assert !ints.contains('vgc_wb_gate'), 'a pointer-free map value is gated:\n${ints}'
}
