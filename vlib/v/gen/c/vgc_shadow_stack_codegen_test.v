// cx-home/v#74 pieces 1, 5 and 6: under -gc e (the default; -d vgc_byte_stack_scan
// turns it off) every local whose type clang can cut off a word — a reference
// that follows a field narrower than a word: an option temporary (a state byte,
// then its error), a struct with a leading tag, such a struct passed by value —
// is followed by vgc_ss_escape(&name). A type that cannot be cut that way gets
// none: a string and a dynamic array (the data pointer is the first word), a
// struct of references followed by small fields, a scalar, a pointer-free
// struct. The -d vgc_byte_stack_scan build emits no escape.
import os

const vgc_ss_codegen_vexe = @VEXE

const vgc_ss_src = "struct Wide {\n\ttag u8\n\tbuf []u8\n}\n\nstruct Lean {\n\tname string\n\tn int\n}\n\nstruct Flat {\n\ta int\n\tb u8\n}\n\nfn find(n int) ?Wide {\n\tif n > 0 {\n\t\treturn Wide{tag: 1, buf: []u8{len: n}}\n\t}\n\treturn none\n}\n\nfn keep(w Wide, l Lean, f Flat) int {\n\treturn w.buf.len + l.name.len + f.a\n}\n\nfn main() {\n\tcount := 3\n\tname := 'x'.repeat(count)\n\tw := find(count) or { Wide{} }\n\tl := Lean{name: name, n: 1}\n\tf := Flat{a: 1}\n\tprintln(keep(w, l, f) + name.len)\n}\n"

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

fn test_the_build_escapes_only_the_locals_clang_can_cut_off_a_word() {
	c := gen_c('')
	main_body := fn_body(c, 'void main__main(void) {')
	assert main_body != '', c
	assert main_body.contains('main__Wide w = '), main_body
	assert main_body.contains('vgc_ss_escape(&w);'), main_body
	assert main_body.contains('_option_main__Wide _t'), main_body
	assert main_body.contains('vgc_ss_escape(&_t'), main_body
	// the data pointer is a string's first word; Lean's one reference comes
	// before its ints
	assert main_body.contains('string name = '), main_body
	assert !main_body.contains('vgc_ss_escape(&name)'), main_body
	assert main_body.contains('main__Lean l = '), main_body
	assert !main_body.contains('vgc_ss_escape(&l)'), main_body
	assert !main_body.contains('vgc_ss_escape(&count)'), main_body
	assert !main_body.contains('vgc_ss_escape(&f)'), main_body
	keep_body := fn_body(c, 'int main__keep(main__Wide w, main__Lean l, main__Flat f) {')
	assert keep_body.contains('vgc_ss_escape(&w);'), keep_body
	assert !keep_body.contains('vgc_ss_escape(&l)'), keep_body
	assert !keep_body.contains('vgc_ss_escape(&f)'), keep_body
}

fn test_the_byte_scan_build_emits_no_escape() {
	c := gen_c('-d vgc_byte_stack_scan')
	assert !c.contains('vgc_ss_escape(&'), 'the -d vgc_byte_stack_scan build carries an escape'
}
