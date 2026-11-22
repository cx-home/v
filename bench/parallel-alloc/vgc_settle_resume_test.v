// vgc_settle_resume_test.v — cx-private#2078: every thread_suspend the
// stop-the-world makes is paired with a thread_resume, on every return of the
// settle.
//
// The darwin stop suspends a straggler in two passes: vgc_suspend_request
// (thread_suspend) and vgc_suspend_settle (wait until it is off-CPU, capture its
// registers). The resume loop resumes only the slots whose settle returned 1.
// Two returns of the settle came after a successful thread_suspend and resumed
// nothing: the record no longer naming the target, and thread_info failing
// (0xdead5). A thread taken through either stayed frozen for the life of the
// process: pbm1's store daemons held 121 answer threads in time.sleep's
// nanosleep for hours while the world ran (sample of p2m2t n3 at t=43,200 s).
//
// A thread spins in C (no safepoint, so the collector can only suspend it). The
// test hook vgc_test_settle_fail makes that thread's next settle take one of
// the two returns; a collection runs; then the thread must be running again:
// suspend count 0 and its counter moving.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_settle_resume_test.v
module main

import time

#flag -I @DIR/vgc_settle_resume
#include "settle_spin.h"

fn C.vgc_settle_spin(stop &int, ctr &u64)
fn C.vgc_settle_suspend_count(port u32) int
fn C.vgc_settle_resume_all(port u32)
fn C.vgc_settle_load_u32(p &u32) u32
fn C.vgc_settle_store_u32(p &u32, v u32)
fn C.vgc_settle_load_u64(p &u64) u64
fn C.vgc_settle_store_int(p &int, v int)
fn C.vgc_test_settle_fail(mode int, port u32)
fn C.vgc_test_settle_fail_taken() int
fn C.vgc_thread_self_port() u32

@[heap]
struct Spinner {
mut:
	stop int
	ctr  u64
	port u32
}

fn spin(mut s Spinner) {
	// a thread takes its collector slot at its first allocation
	mut b := []u8{len: 64}
	b[0] = 1
	C.vgc_settle_store_u32(&s.port, C.vgc_thread_self_port() + u32(b[0]) - 1)
	C.vgc_settle_spin(&s.stop, &s.ctr)
}

struct Outcome {
	taken int
	susp  int
	moved u64
}

fn run_mode(mode int) Outcome {
	mut s := &Spinner{}
	t := spawn spin(mut s)
	for C.vgc_settle_load_u32(&s.port) == 0 {
		time.sleep(time.millisecond)
	}
	port := C.vgc_settle_load_u32(&s.port)
	before := C.vgc_test_settle_fail_taken()
	C.vgc_test_settle_fail(mode, port)
	for _ in 0 .. 50 {
		gc_collect()
		if C.vgc_test_settle_fail_taken() > before {
			break
		}
	}
	C.vgc_test_settle_fail(0, 0)
	taken := C.vgc_test_settle_fail_taken() - before
	time.sleep(50 * time.millisecond)
	c0 := C.vgc_settle_load_u64(&s.ctr)
	time.sleep(300 * time.millisecond)
	c1 := C.vgc_settle_load_u64(&s.ctr)
	susp := C.vgc_settle_suspend_count(port)
	if susp > 0 {
		C.vgc_settle_resume_all(port) // a red run still finishes
	}
	C.vgc_settle_store_int(&s.stop, 1)
	t.wait()
	println('vgc_settle_resume: mode=${mode} port=${port} taken=${taken} suspend_count=${susp} moved=${c1 - c0}')
	return Outcome{
		taken: taken
		susp:  susp
		moved: c1 - c0
	}
}

fn test_a_settle_whose_record_lost_the_target_resumes_it() {
	$if macos && vgc ? {
		o := run_mode(1)
		assert o.taken == 1, 'the hook did not fire: the spinning thread was never settled'
		assert o.susp == 0, 'the thread is left suspended (count ${o.susp}) after the cycle'
		assert o.moved > 0, 'the thread did not run in the 300 ms after the cycle'
	}
}

fn test_a_settle_whose_thread_info_failed_resumes_it() {
	$if macos && vgc ? {
		o := run_mode(2)
		assert o.taken == 1, 'the hook did not fire: the spinning thread was never settled'
		assert o.susp == 0, 'the thread is left suspended (count ${o.susp}) after the cycle'
		assert o.moved > 0, 'the thread did not run in the 300 ms after the cycle'
	}
}
