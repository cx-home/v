// vgc_asan_test.v — a vgc program built with -fsanitize=address starts, runs
// collections with threads and exits 0 (cx-home/v#92).
//
// The collector reads stacks, registers and the data segment conservatively,
// word by word. ASan poisons the redzones around stack locals and globals, so
// an instrumented scan aborts at its first read of one: every cx built with
// plain -fsanitize=address died at start-up with 'stack-buffer-overflow READ
// in vgc_preheap_guard' (vgc_platform.h), and the store's ASan kind runs needed
// --param asan-stack=0 --param asan-globals=0, which loses stack checking.
// With detect_stack_use_after_return on, ASan also moves an escaping local into
// a fake-stack frame off the machine stack: a scan of the stack alone misses
// the references it holds, and their objects are swept while live.
//
// Shape: asan/asan_child.v (threads, lists held only in frames and in an
// escaping local array, collections, garbage churn, checksums) is built with
// -cflags -fsanitize=address under -gc vgc and -gc e and run with
// detect_stack_use_after_return off and on. Each run must exit 0, print
// 'ASAN-CHILD OK' and report nothing from AddressSanitizer.
//
// Run: ./v test bench/parallel-alloc/vgc_asan_test.v
module main

import os

const child_src = os.join_path(@DIR, 'asan', 'asan_child.v')

fn cc_has_asan() bool {
	$if windows {
		return false
	}
	src := os.join_path(os.vtmp_dir(), 'vgc_asan_probe_${os.getpid()}.c')
	exe := src + '.exe'
	os.write_file(src, 'int main(void) { return 0; }\n') or { return false }
	defer {
		os.rm(src) or {}
		os.rm(exe) or {}
	}
	r := os.execute('cc -fsanitize=address -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	return r.exit_code == 0
}

fn build_child(gc string) string {
	exe := os.join_path(os.vtmp_dir(), 'vgc_asan_child_${gc}_${os.getpid()}')
	cmd := '${os.quoted_path(@VEXE)} -gc ${gc} -cc cc -cflags "-fsanitize=address -fno-omit-frame-pointer" -o ${os.quoted_path(exe)} ${os.quoted_path(child_src)}'
	r := os.execute(cmd)
	assert r.exit_code == 0, 'build failed: ${cmd}\n${r.output}'
	return exe
}

fn run_child(exe string, uar int) {
	opts := 'detect_stack_use_after_return=${uar}:detect_leaks=0:abort_on_error=0'
	r := os.execute('ASAN_OPTIONS=${opts} ${os.quoted_path(exe)}')
	ctx := '${os.file_name(exe)} ASAN_OPTIONS=${opts} exit ${r.exit_code}\n${r.output}'
	assert !r.output.contains('AddressSanitizer'), ctx
	assert r.exit_code == 0, ctx
	assert r.output.contains('ASAN-CHILD OK'), ctx
}

fn check(gc string) {
	if !cc_has_asan() {
		println('cc has no -fsanitize=address here: nothing to test')
		return
	}
	exe := build_child(gc)
	defer {
		os.rm(exe) or {}
	}
	run_child(exe, 0)
	run_child(exe, 1)
}

fn test_asan_build_runs_under_vgc() {
	check('vgc')
}

fn test_asan_build_runs_under_gc_e() {
	check('e')
}
