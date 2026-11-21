// cx-home/v#74 piece 1: under -gc e -d vgc_shadow_stack every local of a
// reference-carrying aggregate type (an option temporary, a string, a struct
// with a pointer, a by-value aggregate parameter) is followed by
// vgc_ss_escape(&name), so clang keeps it whole in an aligned slot; a scalar
// local and a pointer-free struct are not; the default build emits no escape.
import os

const vgc_ss_codegen_vexe = @VEXE

const vgc_ss_src = "struct Wide {\n\ttag u8\n\tbuf []u8\n}\n\nstruct Flat {\n\ta int\n\tb u8\n}\n\nfn find(n int) ?Wide {\n\tif n > 0 {\n\t\treturn Wide{tag: 1, buf: []u8{len: n}}\n\t}\n\treturn none\n}\n\nfn keep(w Wide, f Flat) int {\n\treturn w.buf.len + f.a\n}\n\nfn main() {\n\tcount := 3\n\tname := 'x'.repeat(count)\n\tw := find(count) or { Wide{} }\n\tf := Flat{a: 1}\n\tprintln(keep(w, f) + name.len)\n}\n"

fn gen_c(flags string) string {
	tmp_dir := os.join_path(os.vtmp_dir(), 'vgc_ss_codegen_${os.getpid()}')
	os.mkdir_all(tmp_dir) or { panic(err) }
	src := os.join_path(os.real_path(tmp_dir), 'vgc_ss.vv')
	os.write_file(src, vgc_ss_src) or { panic(err) }
	cmd := '${os.quoted_path(vgc_ss_codegen_vexe)} -gc e ${flags} -o - ${os.quoted_path(src)}'
	res := os.execute(cmd)
	os.rmdir_all(tmp_dir) or {}
	assert res.exit_code == 0, '${cmd}\n${res.output}'
	return res.output
}

fn fn_body(c string, head string) string {
	i := c.index(head) or { return '' }
	rest := c[i..]
	j := rest.index('\n}\n') or { return rest }
	return rest[..j]
}

fn test_shadow_build_escapes_reference_carrying_locals_only() {
	c := gen_c('-d vgc_shadow_stack')
	main_body := fn_body(c, 'void main__main(void) {')
	assert main_body != '', c
	assert main_body.contains('string name = '), main_body
	assert main_body.contains('vgc_ss_escape(&name);'), main_body
	assert main_body.contains('main__Wide w = '), main_body
	assert main_body.contains('vgc_ss_escape(&w);'), main_body
	assert main_body.contains('_option_main__Wide _t'), main_body
	assert !main_body.contains('vgc_ss_escape(&count)'), main_body
	assert !main_body.contains('vgc_ss_escape(&f)'), main_body
	keep_body := fn_body(c, 'int main__keep(main__Wide w, main__Flat f) {')
	assert keep_body.contains('vgc_ss_escape(&w);'), keep_body
	assert !keep_body.contains('vgc_ss_escape(&f)'), keep_body
}

fn test_default_build_emits_no_escape() {
	c := gen_c('')
	assert !c.contains('vgc_ss_escape(&'), 'the default -gc e build carries an escape'
}
