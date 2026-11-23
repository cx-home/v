// vgc_no_weak_export_test.v — cx-home/v#74 (reopened): an executable built with -gc e exports no
// weak definition. vgc_ss_unknown (vgc_platform.h, b822dfd129 piece 5) was a plain weak external:
// dyld coalesces every exported weak definition across the loaded images at each launch, and cx's
// cli_umbrella_test (test_cx_build_executable_exports_no_weak_definition, cx-private#1934) fails on
// `weak external _vgc_ss_unknown` in a built executable. A hidden weak definition stays one the
// compiler cannot know (a link may replace it), and exports nothing. Mach-O only (nm -m).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_no_weak_export_test.v
module main

import os

fn test_a_gc_e_executable_exports_no_weak_definition() {
	$if !macos {
		return
	}
	dir := os.join_path(os.vtmp_dir(), 'vgc_no_weak_export_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	src := os.join_path(dir, 'hello.v')
	exe := os.join_path(dir, 'hello')
	os.write_file(src, 'fn main() {\n\tmut a := []string{}\n\tfor i in 0 .. 1000 {\n\t\ta << i.str()\n\t}\n\tprintln(a.len)\n}\n') or {
		panic(err)
	}
	b := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b.exit_code == 0, b.output
	r := os.execute(os.quoted_path(exe))
	assert r.exit_code == 0 && r.output.trim_space() == '1000', r.output
	syms := os.execute('nm -m ${os.quoted_path(exe)}')
	assert syms.exit_code == 0, syms.output
	weak := syms.output.split_into_lines().filter(it.contains('weak external'))
	assert weak.len == 0, 'a -gc e executable exports weak definitions dyld coalesces at every launch: ${weak}'
}
