// ok_wrap_initializer_form_test.v — cx-private#1924, the cgen initializer form:
// a plain value wrapped into an option or a result is written by the caller,
// the header in the declaration's initializer and the payload stored into
// .data (`_option_int _t1 = {.state=0,.err=_const_none__}; *(int*)_t1.data =
// …;`), not declared bare (`_option_int _t1;`) and filled by a call to
// builtin___option_ok, so the zero-store a -ftrivial-auto-var-init build gives
// the bare declaration is dead. A fixed array keeps the ok-wrap call (the
// control). The program's answers are the same either way.
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

const src = os.join_path(os.dir(@FILE), 'testdata', 'ok_wrap', 'ok_wraps.vv')

fn test_a_plain_value_is_wrapped_in_the_initializer_form() {
	out := os.join_path(os.vtmp_dir(), 'ok_wrap_form_${os.getpid()}.c')
	res := os.execute('${os.quoted_path(vexe)} -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file(out)!
	os.rm(out) or {}
	for name, payload in {
		'main__opt_int':   'int'
		'main__res_str':   'string'
		'main__opt_point': 'main__Point'
		'main__res_u8':    'u8'
		'main__opt_ref':   'main__Point*'
		'main__opt_arr':   'Array_int'
		'main__res_call':  'int'
	} {
		body := fn_body(c, name)
		assert body.len > 0, '${name} not emitted'
		hdr := if name.starts_with('main__opt') { '.state=0' } else { '.is_error=0' }
		assert body.contains(' = {${hdr},.err=_const_none__};'), '${name}: no initializer form:\n${body}'
		assert body.contains('*(${payload}*)_t'), '${name}: the payload is not stored:\n${body}'
		assert !body.contains('builtin___option_ok(') && !body.contains('builtin___result_ok('), '${name} still calls the ok-wrap:\n${body}'
	}
	fixed := fn_body(c, 'main__opt_fixed')
	assert fixed.contains('builtin___option_ok('), 'the fixed-array control lost its ok-wrap call:\n${fixed}'
}

fn test_the_answers_are_the_wrapped_values() {
	for gc in ['', '-gc e'] {
		res := os.execute('${os.quoted_path(vexe)} ${gc} run ${os.quoted_path(src)}')
		assert res.exit_code == 0, res.output
		assert res.output.trim_space().split_into_lines() == ['42', '-1', 'n=7', 'negative -7',
			'5 2.5 p5', 'none', '200', '0', 'q', '[0, 1, 2, 3]', '[1, 2, 3]', '21'], '${gc}: ${res.output}'
	}
}
