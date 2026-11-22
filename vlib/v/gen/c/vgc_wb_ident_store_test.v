// vgc_wb_ident_store_test.v — https://github.com/cx-home/v/issues/83: an assignment
// whose target is an identifier that C reaches through a pointer stores into a
// heap object as surely as `*p = v` does, and takes the same write-barrier gate
// under the concurrent mark: a `mut` parameter of a struct type (`*s = v`, the
// caller's memory: a heap object's field, an array element), a `for mut` element
// (`*e = v`, the array's buffer), and an auto-heap local (`*box = v` and
// `box->r = v`, its heap box). Without the gate an old object that the markers
// had already scanned took a pointer to a record that was still white, and the
// record was swept while the object still named it
// (bench/parallel-alloc/vgc_cm_ident_test.v). A plain local is the stack and a
// struct with no pointer needs no gate (the controls).
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

// gated reports whether the store line `store` comes right after a gate on `base`
fn gated(body string, base string, store string) bool {
	lines := body.split_into_lines().map(it.trim_space())
	for i, l in lines {
		if l.starts_with(store) {
			for j := i - 1; j >= 0 && j >= i - 3; j-- {
				if lines[j] == 'vgc_wb_gate((voidptr)(${base}));' {
					return true
				}
			}
			return false
		}
	}
	return false
}

fn test_a_store_through_an_identifiers_pointer_is_gated() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'ident_store.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_ident_store_${os.getpid()}.c')
	res := os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file(out)!
	os.rm(out) or {}
	put := fn_body(c, 'main__put')
	assert gated(put, 's', '*s = v;'), 'the mut parameter store is not gated:\n${put}'
	each := fn_body(c, 'main__put_each')
	assert gated(each, 'e', '*e = '), 'the for-mut element store is not gated:\n${each}'
	boxed := fn_body(c, 'main__boxed')
	assert gated(boxed, 'box', '*box = '), 'the auto-heap local store is not gated:\n${boxed}'
	assert gated(boxed, 'box', 'box->r = r;'), 'the auto-heap local field store is not gated:\n${boxed}'
	plain := fn_body(c, 'main__put_plain')
	assert !plain.contains('vgc_wb_gate'), 'a struct with no pointer is gated:\n${plain}'
	local := fn_body(c, 'main__local')
	assert !local.contains('vgc_wb_gate'), 'a plain local (the stack) is gated:\n${local}'
	println('vgc_wb_ident_store: mut parameter, for-mut element, auto-heap local gated; controls ungated')
}
