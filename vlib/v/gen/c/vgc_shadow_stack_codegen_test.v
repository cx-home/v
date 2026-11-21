// cx-home/v#74 pieces 1, 5 and 6: under -gc e (the default; -d vgc_byte_stack_scan
// turns it off) the declaration of every local clang can cut off a word is
// followed by vgc_ss_ref(x, <offset>) for each word of it that holds a field
// narrower than a word with a reference behind it: an option temporary's state
// byte and its error's tag, the leading tag of a struct with a buffer, the same
// for such a struct passed by value. A type that cannot be cut that way gets
// nothing: a string (the data pointer is the first word), a struct whose one
// reference comes before its ints, a scalar, a pointer-free struct. A map gets
// vgc_ss_pin(&m), the address form. The -d vgc_byte_stack_scan build emits
// neither.
import os

const vgc_ss_codegen_vexe = @VEXE

const vgc_ss_src = "struct Wide {\n\ttag u8\n\tbuf []u8\n}\n\nstruct Lean {\n\tname string\n\tn int\n}\n\nstruct Flat {\n\ta int\n\tb u8\n}\n\nfn find(n int) ?Wide {\n\tif n > 0 {\n\t\treturn Wide{tag: 1, buf: []u8{len: n}}\n\t}\n\treturn none\n}\n\nfn keep(w Wide, l Lean, f Flat) int {\n\treturn w.buf.len + l.name.len + f.a\n}\n\nfn main() {\n\tcount := 3\n\tname := 'x'.repeat(count)\n\tw := find(count) or { Wide{} }\n\tl := Lean{name: name, n: 1}\n\tf := Flat{a: 1}\n\tmut m := map[string]int{}\n\tm[name] = 1\n\tprintln(keep(w, l, f) + name.len + m.len)\n}\n"

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

fn test_the_build_reads_the_words_whose_narrow_field_can_cut_a_reference_off_a_word() {
	c := gen_c('')
	main_body := fn_body(c, 'void main__main(void) {')
	assert main_body != '', c
	// Wide { tag u8; buf []u8 }: the tag's word
	assert main_body.contains('main__Wide w = '), main_body
	assert main_body.contains(' vgc_ss_ref(w, 0 + __builtin_offsetof(main__Wide, tag));'), main_body
	// ?Wide: the state byte's word, the error's tag, the value's tag
	assert main_body.contains('_option_main__Wide _t1 = main__find(count); vgc_ss_ref(_t1, 0); vgc_ss_ref(_t1, 0 + __builtin_offsetof(_option_main__Wide, err) + 8); vgc_ss_ref(_t1, 0 + __builtin_offsetof(_option_main__Wide, data) + __builtin_offsetof(main__Wide, tag));'), main_body
	// the data pointer is a string's first word; Lean's one reference comes
	// before its ints
	assert main_body.contains('string name = '), main_body
	assert !main_body.contains('(name,') && !main_body.contains('(&name)'), main_body
	assert main_body.contains('main__Lean l = '), main_body
	assert !main_body.contains('vgc_ss_ref(l,') && !main_body.contains('vgc_ss_pin(&l)'), main_body
	assert !main_body.contains('vgc_ss_ref(count,') && !main_body.contains('vgc_ss_pin(&count)'), main_body
	assert !main_body.contains('vgc_ss_ref(f,') && !main_body.contains('vgc_ss_pin(&f)'), main_body
	// a map is pinned whole (every map operation takes its address anyway)
	assert main_body.contains(' vgc_ss_pin(&m);'), main_body
	keep_body := fn_body(c, 'int main__keep(main__Wide w, main__Lean l, main__Flat f) {')
	assert keep_body.contains('vgc_ss_ref(w, 0 + __builtin_offsetof(main__Wide, tag));'), keep_body
	assert !keep_body.contains('vgc_ss_ref(l,') && !keep_body.contains('vgc_ss_ref(f,'), keep_body
	assert !c.contains('vgc_ss_escape('), 'the address-of-everything escape is gone'
}

fn test_the_byte_scan_build_emits_no_escape() {
	c := gen_c('-d vgc_byte_stack_scan')
	assert !c.contains('vgc_ss_ref(') && !c.contains('vgc_ss_pin('), 'the -d vgc_byte_stack_scan build carries an escape'
}
