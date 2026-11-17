// cx-home/v#72: builtin's vgc code builds clean on every path a program takes.
// (1) `-cross` checks every top-level `$if vgc ? {}` arm while it compiles the
//     non-vgc runtime, so each name those arms read needs a stub in
//     vgc_notd_vgc.c.v (cx-private#1888) — gc_collect, gc_total_allocated and
//     gc_thread_allocated read names that had none.
// (2) a default (-gc e) build of a program prints nothing from builtin: the
//     vgc runtime's own checker notices reached every program's output
//     (coutput_test's autofree_nested_interpolation_nix case read them).
import os

const vexe = @VEXE

const tdir = os.join_path(os.vtmp_dir(), 'vgc_builtin_builds_clean_${os.getpid()}')

fn testsuite_begin() {
	os.mkdir_all(tdir) or {}
	os.write_file(os.join_path(tdir, 'prog.v'), "println('hello')\n") or { panic(err) }
}

fn testsuite_end() {
	os.rmdir_all(tdir) or {}
}

fn test_cross_build_of_a_program_compiles_builtin() {
	src := os.join_path(tdir, 'prog.v')
	out := os.join_path(tdir, 'prog_cross.c')
	res := os.execute('${os.quoted_path(vexe)} -cross -o ${os.quoted_path(out)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	assert !res.output.contains('vlib/builtin/'), res.output
}

fn test_default_build_of_a_program_prints_nothing_from_builtin() {
	src := os.join_path(tdir, 'prog.v')
	exe := os.join_path(tdir, 'prog_default')
	res := os.execute('${os.quoted_path(vexe)} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	assert !res.output.contains('vlib/builtin/'), res.output
	run := os.execute(os.quoted_path(exe))
	assert run.exit_code == 0
	assert run.output.trim_space() == 'hello'
}
