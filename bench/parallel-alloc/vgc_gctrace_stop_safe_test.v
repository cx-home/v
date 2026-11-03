// vgc_gctrace_stop_safe_test.v — cx-home/v#62: a trace line written while the world is
// stopped goes through the collector's own writer (vgc__ws / vgc__wdec: write(2), no lock),
// never libc's formatted output. The pace line (VGC_GCTRACE=2) went through fprintf, whose
// formatter takes libc's locale lock; a mutator stopped inside snprintf (net.Ip.str's
// inet_ntop4 in an HTTP handler) held that lock, and the collector waited on it for good:
// http-json-echo k=4 C=256 under VGC_GCTRACE=2 hung at cycle 404 (the collector in
// fprintf -> localeconv_l -> os_unfair_lock, a handler in inet_ntop4 -> snprintf ->
// localeconv_l; sample of the hung server, misc-epic d2, 2026-11-03).
//
// gctrace_stop_safe/locale_churn.v runs threads that allocate and call snprintf; the test
// runs it at VGC_GCTRACE=2 under a deadline and asks for completion, its pace lines and one
// pace line per collection line.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_gctrace_stop_safe_test.v
module main

import os

fn build_fixture() string {
	src := os.join_path(@DIR, 'gctrace_stop_safe', 'locale_churn.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_locale_churn_${os.getpid()}')
	r := os.execute('${os.quoted_path(@VEXE)} -gc e -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

// run_with_deadline runs exe at VGC_GCTRACE=2 under perl's alarm (SIGALRM ends a hung run)
// and returns (finished, stdout, stderr).
fn run_with_deadline(exe string, secs int) (bool, string, string) {
	o := '${exe}.out'
	e := '${exe}.err'
	defer {
		os.rm(o) or {}
		os.rm(e) or {}
	}
	r := os.execute("perl -e 'alarm ${secs}; exec @ARGV' env VGC_GCTRACE=2 ${os.quoted_path(exe)} > ${os.quoted_path(o)} 2> ${os.quoted_path(e)}")
	out := os.read_file(o) or { '' }
	err := os.read_file(e) or { '' }
	return r.exit_code == 0, out, err
}

fn test_trace_lines_under_the_stop_do_not_wait_on_libc_locks() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	for run in 0 .. 3 {
		ok, out, err := run_with_deadline(exe, 60)
		assert ok, 'run ${run}: no completion in 60 s at VGC_GCTRACE=2 (a stop waiting on a libc lock); last trace: ${err#[-400..]}'
		assert out.contains('done'), 'run ${run}: ${out}'
		lines := err.split_into_lines()
		gc := lines.filter(it.starts_with('[gc ') && it.contains(' marked=')).len
		pace := lines.filter(it.starts_with('[gc ') && it.contains('] pace nt=')).len
		assert gc > 100, 'run ${run}: ${gc} collections (want > 100 for the churn to mean anything)'
		assert pace == gc, 'run ${run}: ${pace} pace lines for ${gc} collections'
	}
}
