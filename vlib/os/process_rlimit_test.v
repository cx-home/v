import os

// cx-home/cx-core-code#143: Process.set_rlimit applies a resource limit in the child
// between fork and exec; the parent's own limit is unchanged.
fn test_set_rlimit_applies_in_the_child_only() {
	$if windows {
		return
	}
	before := os.execute('/bin/sh -c "ulimit -n"').output.trim_space()
	mut p := os.new_process('/bin/sh')
	p.set_args(['-c', 'ulimit -n'])
	p.set_rlimit(int(C.RLIMIT_NOFILE), 200, 200)
	p.set_redirect_stdio()
	p.run()
	p.wait()
	assert p.code == 0
	assert p.stdout_slurp().trim_space() == '200'
	p.close()
	after := os.execute('/bin/sh -c "ulimit -n"').output.trim_space()
	assert after == before, 'the parent limit moved: ${before} -> ${after}'
}

fn test_a_limit_the_child_cannot_set_exits_127() {
	$if windows {
		return
	}
	mut p := os.new_process('/bin/sh')
	p.set_args(['-c', 'echo ran'])
	// a soft value above the hard one is refused by setrlimit (EINVAL)
	p.set_rlimit(int(C.RLIMIT_NOFILE), 300, 200)
	p.set_redirect_stdio()
	p.run()
	p.wait()
	assert p.code == 127
	assert p.stdout_slurp().trim_space() == ''
	assert p.stderr_slurp().contains('setrlimit')
	p.close()
}
