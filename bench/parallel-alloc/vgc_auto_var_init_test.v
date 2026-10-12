// vgc_auto_var_init_test.v — cx-private#1910 cut 1: a `-gc e` build passes
// -ftrivial-auto-var-init=zero to a clang or gcc that accepts it (the builder
// probes once per compiler), and -d vgc_no_auto_var_init leaves it out.
// cx-private#1922: on a compiler that accepts -ftrivial-auto-var-init-max-size
// (clang) the clearing is capped at 32 bytes; -d vgc_auto_var_init_nocap
// clears every size.
//
// The collector scans the mutators' stacks conservatively, so a frame's
// never-written slots carry residue of deeper frames: heap pointers of objects
// long dropped, each retaining a subtree. json-codec 1 MB x100 read 72 MB
// peak RSS against 59 on the previous fork pin from the runtime's frame-layout
// shift alone (364 objects shaded from the stacks against 279, the data
// segments identical); with the flag 57 MB, time unchanged.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_auto_var_init_test.v
module main

import os

const flag = '-ftrivial-auto-var-init=zero'
const cap = '-ftrivial-auto-var-init-max-size=32'

fn cc_accepts(flags string) bool {
	src := os.join_path(os.vtmp_dir(), 'vgc_avi_test_${os.getpid()}.c')
	obj := src + '.o'
	os.write_file(src, 'int main(void) { return 0; }\n') or { return false }
	defer {
		os.rm(src) or {}
		os.rm(obj) or {}
	}
	r := os.execute('cc ${flags} -Werror -c -o ${os.quoted_path(obj)} ${os.quoted_path(src)}')
	return r.exit_code == 0
}

fn cc_accepts_the_flag() bool {
	return cc_accepts(flag)
}

fn showcc(defines string) string {
	src := os.join_path(@DIR, 'concurrent_born', 'born.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_avi_showcc_${os.getpid()}')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -showcc ${defines} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return r.output
}

fn test_vgc_builds_zero_initialize_automatics() {
	if !cc_accepts_the_flag() {
		println('cc does not accept ${flag}: the builder leaves it out; nothing to test here')
		return
	}
	out := showcc('')
	assert out.contains(flag), 'the -gc e build does not pass ${flag}:\n${out}'
	if cc_accepts('${flag} ${cap}') {
		assert out.contains(cap), 'cc accepts ${cap} but the -gc e build does not cap the clearing:\n${out}'
	} else {
		assert !out.contains(cap), 'cc refuses ${cap} but the build passes it:\n${out}'
	}
}

fn test_the_nocap_define_clears_every_size() {
	if !cc_accepts_the_flag() {
		return
	}
	out := showcc('-d vgc_auto_var_init_nocap')
	assert out.contains(flag), 'the nocap build dropped ${flag}:\n${out}'
	assert !out.contains(cap), 'the -d vgc_auto_var_init_nocap build still caps the clearing:\n${out}'
}

fn test_the_define_leaves_the_flag_out() {
	out := showcc('-d vgc_no_auto_var_init')
	assert !out.contains(flag), 'the -d vgc_no_auto_var_init build still passes ${flag}:\n${out}'
}
