// vgc_wb_meta_test.v — cx-private#1924 cut 3: a store into the collector's own
// metadata (a span descriptor's list links, a central list head, a mark work
// buffer) carries no write-barrier gate: every VGC_* metadata struct is carved
// from vgc_os_alloc slabs or is the vgc_heap global, never a heap object, so the
// gate records nothing there. A field store through a pointer in user code keeps
// its gates (the control).
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

fn test_the_collectors_metadata_stores_carry_no_gate() {
	src := os.join_path(os.dir(@FILE), 'testdata', 'vgc_wb', 'ok_wraps.vv')
	out := os.join_path(os.vtmp_dir(), 'vgc_wb_meta_${os.getpid()}.c')
	res := os.execute('${os.quoted_path(vexe)} -gc e -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	c := os.read_file(out)!
	os.rm(out) or {}
	for name in ['builtin__vgc_pool_push', 'builtin__vgc_pool_unlink', 'builtin__vgc_central_get_span',
		'builtin__vgc_sweep_span_apply', 'builtin__vgc_work_put'] {
		body := fn_body(c, name)
		assert body.len > 0, '${name} not emitted'
		assert !body.contains('vgc_wb_gate'), '${name} still gates a metadata store:\n${body}'
	}
	store := fn_body(c, 'main__store')
	assert store.count('vgc_wb_gate((voidptr)(b));') >= 1, 'the control lost its gate:\n${store}'
	println('vgc_wb_meta: collector metadata stores ungated, main.store gated')
}
