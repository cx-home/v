// cx-home/v#18: `v build-module <dir>` probed the module's SOURCE directory for
// writability (a mkstemp + rm inside it) before cc() pointed out_name at the
// cache. Every -usecache miss moved the module directory's mtime, and a
// read-only module tree could not be built into the cache at all.
import os

const vexe = @VEXE

fn test_build_module_leaves_a_read_only_source_dir_alone() {
	$if windows {
		return
	}
	root := os.join_path(os.vtmp_dir(), 'v18_ro_src_${os.getpid()}')
	os.rmdir_all(root) or {}
	moddir := os.join_path(root, 'mymod')
	cache := os.join_path(root, 'cache')
	os.mkdir_all(moddir)!
	os.mkdir_all(cache)!
	os.write_file(os.join_path(moddir, 'mymod.v'),
		'module mymod\n\npub fn answer() int {\n\treturn 42\n}\n')!
	os.chmod(moddir, 0o555)!
	defer {
		os.chmod(moddir, 0o755) or {}
		os.rmdir_all(root) or {}
	}
	before := os.stat(moddir)!.mtime
	os.setenv('VCACHE', cache, true)
	res := os.execute('${os.quoted_path(vexe)} build-module ${os.quoted_path(moddir)}')
	os.unsetenv('VCACHE')
	assert res.exit_code == 0, res.output
	assert os.stat(moddir)!.mtime == before, 'build-module wrote into the module source directory'
	assert os.ls(moddir)! == ['mymod.v']
}
