// vgc_wb_ok_wraps_test.v — cx-private#1924 cut 3: the option/result ok-wraps
// (and _option_none) store the wrapper header without a barrier
// (@[vgc_no_wb]: the header's one pointer is none__'s object, which a global
// const roots, so the store records no edge the collector needs). They were
// 31.5 M of template-render 5000's 43 M executed gates. A field store through
// a pointer in user code keeps its gates (the control).
import os

const vexe = @VEXE

// the definition's body (the line naming the function and opening its brace,
// then every line up to the closing one), not a prototype's
fn fn_body(c string, name string) string {
	mut out := []string{}
	mut inside := false
	for l in c.split_into_lines() {
		if !inside {
			inside = l.contains('void ${name}(') && l.trim_space().ends_with('{')
			continue
		}
		if l == '}' {
			break
		}
		out << l
	}
	return out.join('\n')
}

fn test_the_ok_wraps_store_their_header_without_a_barrier() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'ok_wraps.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_ok_wraps_${os.getpid()}.c')
	res := os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file(out)!
	os.rm(out) or {}
	for name in ['builtin___option_ok', 'builtin___result_ok', 'builtin___option_none'] {
		body := fn_body(c, name)
		assert body.len > 0, '${name} not emitted'
		assert !body.contains('vgc_wb_gate'), '${name} still gates its header store:\n${body}'
	}
	store := fn_body(c, 'main__store')
	assert store.count('vgc_wb_gate((voidptr)(b));') >= 1, 'the control lost its gate:\n${store}'
	println('vgc_wb_ok_wraps: ok-wraps ungated, main.store gated')
}
