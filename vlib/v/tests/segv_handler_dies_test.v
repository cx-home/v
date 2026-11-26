// vtest build: !windows && !freestanding
module main

import os
import time

// segv_handler_dies_test.v — a program that takes SIGSEGV must DIE, whatever
// its other threads hold (https://github.com/cx-home/cx-private/issues/2036:
// a store daemon took 'signal 11' after heap corruption and kept serving for
// 9 minutes with its faulting thread gone — RESTARTS 0, Ready — because V's
// handler ran non-async-signal-safe code: a backtrace that allocates, then
// exit(), whose atexit / stdio teardown runs under live threads).
//
// Each case builds a child that faults on its main thread while a second
// thread is alive; the child must be gone within 10 s, killed by SIGSEGV
// (the handler restores the default action and re-raises: os.Process reads
// status .aborted, code 128 + 11).

const segv_child_atexit = '
module main

import sync
import time

fn C.atexit(f fn ()) int

const held = sync.new_mutex()

fn wedge() {
	// an atexit hook that waits on a lock a live thread holds: exit() from
	// the signal handler never returns
	held.lock()
}

fn holder() {
	held.lock()
	for {
		time.sleep(50 * time.millisecond)
	}
}

fn main() {
	C.atexit(wedge)
	spawn holder()
	time.sleep(200 * time.millisecond)
	println("faulting")
	unsafe {
		mut p := &int(nil)
		*p = 1
	}
	println("unreachable")
}
'

const segv_child_plain = '
module main

import time

fn worker() {
	for {
		time.sleep(50 * time.millisecond)
	}
}

fn main() {
	spawn worker()
	time.sleep(200 * time.millisecond)
	println("faulting")
	unsafe {
		mut p := &int(nil)
		*p = 1
	}
	println("unreachable")
}
'

struct SegvRun {
	died     bool
	signaled bool
	code     int
	stderr   string
	wall_ms  i64
}

fn run_segv_child(name string, src string, flags string) SegvRun {
	dir := os.join_path(os.vtmp_dir(), 'segv_handler_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	srcf := os.join_path(dir, '${name}.v')
	exe := os.join_path(dir, name)
	os.write_file(srcf, src) or { panic(err) }
	b :=
		os.execute('${os.quoted_path(@VEXE)} ${flags} -o ${os.quoted_path(exe)} ${os.quoted_path(srcf)}')
	assert b.exit_code == 0, 'build ${name}: ${b.output}'
	mut p := os.new_process(exe)
	p.set_redirect_stdio()
	t0 := time.now()
	p.run()
	for p.is_alive() && time.since(t0) < 10 * time.second {
		time.sleep(20 * time.millisecond)
	}
	wall := time.since(t0).milliseconds()
	died := !p.is_alive()
	signaled := p.status == .aborted
	code := p.code
	if !died {
		p.signal_kill()
		p.wait()
	}
	errs := p.stderr_slurp()
	r := SegvRun{
		died:     died
		signaled: died && signaled
		code:     code
		stderr:   errs
		wall_ms:  wall
	}
	p.close()
	return r
}

fn test_segv_while_an_atexit_hook_would_wedge_kills_the_process() {
	r := run_segv_child('segv_atexit', segv_child_atexit, '')
	eprintln('atexit case: died=${r.died} signaled=${r.signaled} code=${r.code} in ${r.wall_ms} ms')
	assert r.died, 'the process outlived its SIGSEGV by 10 s (the handler wedged in exit()); stderr: ${r.stderr}'
	assert r.stderr.contains('signal 11: segmentation fault')
	assert r.signaled && r.code == 128 + 11, 'expected death by SIGSEGV, got status code ${r.code} (signaled=${r.signaled})'
}

fn test_segv_with_a_live_thread_kills_the_process_by_sigsegv() {
	r := run_segv_child('segv_plain', segv_child_plain, '')
	eprintln('plain case: died=${r.died} signaled=${r.signaled} code=${r.code} in ${r.wall_ms} ms')
	assert r.died
	assert r.stderr.contains('signal 11: segmentation fault')
	assert r.signaled && r.code == 128 + 11
}

fn test_segv_handler_that_hangs_in_its_backtrace_is_killed_by_the_watchdog() {
	// -d segv_handler_hang_test: the handler blocks where the backtrace would
	// run (a fault inside malloc deadlocks the same way on the allocator lock)
	r := run_segv_child('segv_hang', segv_child_plain, '-d segv_handler_hang_test')
	eprintln('hang case: died=${r.died} signaled=${r.signaled} code=${r.code} in ${r.wall_ms} ms')
	assert r.died, 'a handler stuck in its backtrace kept the process alive 10 s'
	assert r.signaled && r.code == 128 + 11
	assert r.stderr.contains('signal 11: segmentation fault')
}
