// vgc_exit_churn_stw_test.v — threads exiting while collections run, with the
// per-thread cache index in a pthread key (cx-home/v#28).
//
// The suspend handler finds its slot through the thread's TLS cache index. On
// the tcc lanes (Linux x86_64, FreeBSD) that index lives in a pthread key, and
// the libc clears every key's value before it runs the key destructors — the
// collector's exit callback among them. A thread exiting while a cycle holds
// cache_lock waits in that callback, the cycle's suspend signal reaches it
// there, its index reads -1, it never acks, and the collector waits for ever
// (CI vgc 38065594231 / 38070815065: vgc_parallel_mark_test's child, which
// exits four builders under forced collections). The handler now falls back
// to a search by thread id when the index does not name its armed record.
//
// exit_churn/churn.v is the fixture, built with -DVGC_FORCE_TLS_BY_KEY (the
// tcc shape under any compiler; on macOS also -DVGC_SIGNAL_SUSPEND, the
// signal path the Linux/FreeBSD collectors use) and once with the default
// flags. Red (watchdog, exit 3) before the fix on the key build; green after.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_exit_churn_stw_test.v
module main

import os

fn build_fixture(cflags string) string {
	src := os.join_path(@DIR, 'exit_churn', 'churn.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_exit_churn_${os.getpid()}_${cflags.len}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e ${cflags} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn run_churn(exe string, label string) {
	r := os.execute('WAVES=200 PER_WAVE=16 WATCHDOG_S=90 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, '${label}: exit ${r.exit_code}: ${r.output}'
	assert r.output.contains(' ok '), '${label}: ${r.output}'
	println('${label}: ${r.output.trim_space()}')
}

fn test_exiting_threads_under_forced_collections_with_tls_by_key() {
	mut flags := '-cflags -DVGC_FORCE_TLS_BY_KEY'
	$if macos {
		flags += ' -cflags -DVGC_SIGNAL_SUSPEND'
	}
	exe := build_fixture(flags)
	defer {
		os.rm(exe) or {}
	}
	run_churn(exe, 'tls-by-key')
}

fn test_exiting_threads_under_forced_collections_default() {
	exe := build_fixture('')
	defer {
		os.rm(exe) or {}
	}
	run_churn(exe, 'default')
}
