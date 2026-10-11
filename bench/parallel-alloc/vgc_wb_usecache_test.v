// cx-private#1910: under -gc e codegen emits the concurrent-mark write barrier
// `vgc_wb_store(...)` before pointer stores in every module. With -usecache each
// cached module (term.termios here) is its own C unit that does not include the
// builtin's @[export] prototype, so the barrier was called undeclared and cc
// refused the module ("call to undeclared function 'vgc_wb_store'"). Every cx
// test binary is built -usecache, so the whole cx suite failed to compile.
import os

const prog = "import term.termios

struct Box {
mut:
	p &int = unsafe { nil }
}

fn main() {
	mut t := termios.Termios{}
	_ = termios.tcgetattr(0, mut t)
	mut b := &Box{}
	x := 7
	b.p = &x
	println('stored \${*b.p}')
}
"

fn test_the_barrier_is_declared_in_cached_module_units() {
	dir := os.join_path(os.vtmp_dir(), 'vgc_wb_usecache_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	src := os.join_path(dir, 'wb_usecache.v')
	os.write_file(src, prog)!
	res := os.execute('${os.quoted_path(@VEXE)} -gc e -usecache run ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
	assert res.output.contains('stored 7'), res.output
}
