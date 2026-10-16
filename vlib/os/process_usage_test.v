// cx-home/v#48: a reaped child's CPU time and peak resident set reach the
// Process — wait4, not waitpid, at the reap — whether wait() or is_alive()
// is the call that sees the exit.
import os
import time

const child_src = '
fn main() {
	mut buf := []u8{len: 50 * 1024 * 1024}
	for i := 0; i < buf.len; i += 4096 {
		buf[i] = u8(i / 4096)
	}
	sw := time.new_stopwatch()
	mut x := u64(1)
	for sw.elapsed().milliseconds() < 250 {
		for _ in 0 .. 100000 {
			x = x * 6364136223846793005 + 1
		}
	}
	println(x + buf[8192])
}
'

const tfolder = os.join_path(os.vtmp_dir(), 'process_usage_test_${os.getpid()}')

const child_exe = os.join_path(tfolder, 'burner')

fn testsuite_begin() {
	os.mkdir_all(tfolder) or {}
	src := os.join_path(tfolder, 'burner.v')
	os.write_file(src, 'import time\n' + child_src) or { panic(err) }
	res :=
		os.execute('${os.quoted_path(@VEXE)} -o ${os.quoted_path(child_exe)} ${os.quoted_path(src)}')
	assert res.exit_code == 0, res.output
}

fn testsuite_end() {
	os.rmdir_all(tfolder) or {}
}

fn check_usage(p &os.Process, how string) {
	println('${how}: user ${p.user_ns / 1_000_000} ms, sys ${p.sys_ns / 1_000_000} ms, peak ${p.peak_rss / (1024 * 1024)} MB')
	assert p.code == 0
	assert p.user_ns >= 150_000_000, '${how}: user ${p.user_ns} ns'
	assert p.peak_rss >= 50 * 1024 * 1024, '${how}: peak ${p.peak_rss} bytes'
}

fn test_wait_reports_the_childs_usage() {
	mut p := os.new_process(child_exe)
	assert p.user_ns == 0 && p.peak_rss == 0
	p.wait()
	check_usage(p, 'wait')
	p.close()
}

fn test_a_reap_by_is_alive_reports_the_childs_usage() {
	mut p := os.new_process(child_exe)
	p.run()
	for p.is_alive() {
		time.sleep(10 * time.millisecond)
	}
	check_usage(p, 'is_alive')
	p.close()
}
