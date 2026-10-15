// vgc_native_attach_test.v — the native-linkage ABI (NATV-18, cx-home/v#47;
// thirdparty/vgc/vgc_native.h), driven from vgc_native_unit.c, a separate C
// translation unit linked into the program as cx's native defs will be.
//
// Eight pthreads the V runtime did not start each hold one GC buffer only in a
// local on their own stack while main collects six times and refills the freed
// slots with other bytes. Attached (vgc_thread_attach), the collector scans
// their stacks and every buffer reads back intact. Not attached, nothing roots
// the buffers: VNA_RED=1 runs that shape and expects it to read wrong (the RED
// witness; not run by default since it relies on the freed slots being reused).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_native_attach_test.v
module main

import os
import time

#flag @DIR/vgc_native_unit.o
#include "@DIR/vgc_native_unit.h"

fn C.vna_start(mode int)
fn C.vna_hand(i int, p voidptr)
fn C.vna_holding_n() int
fn C.vna_finish() int
fn C.vna_new_n() int
fn C.vna_again_n() int
fn C.vna_park(p voidptr)
fn C.vna_parked_bad(b int) int
fn C.vna_unpark()
fn C.vna_gate(obj voidptr)
fn C.vna_abi() int
fn C.vna_safe_roundtrip()
fn C.vna_poll_start(poll int)
fn C.vna_poll_finish() int
fn C.vna_poll_live_n() int
fn C.vna_poll_seen_so_far() int

const vna_n = 8
const vna_len = 2048

@[noinline]
fn hand_one(i int) {
	b := unsafe { malloc(vna_len) }
	unsafe { vmemset(b, 0xA0 + i, vna_len) }
	C.vna_hand(i, b)
}

@[noinline]
fn scrub_stack() int {
	mut a := [4096]u64{}
	for k in 0 .. a.len {
		a[k] = u64(k)
	}
	return int(a[4095])
}

// collect and refill: the freed buffers' slots are handed out again and
// overwritten with 0x11, so a buffer the collector missed reads wrong.
@[noinline]
fn churn() []voidptr {
	mut keep := []voidptr{cap: 6 * 4000}
	for _ in 0 .. 6 {
		gc_collect()
		for _ in 0 .. 4000 {
			p := unsafe { malloc(vna_len) }
			unsafe { vmemset(p, 0x11, vna_len) }
			keep << p
		}
	}
	return keep
}

fn run(mode int) (int, int, int) {
	C.vna_start(mode)
	for i in 0 .. vna_n {
		hand_one(i)
	}
	for C.vna_holding_n() < vna_n {
		time.sleep(time.millisecond)
	}
	_ = scrub_stack()
	keep := churn()
	bad := C.vna_finish()
	assert keep.len == 6 * 4000
	return bad, C.vna_new_n(), C.vna_again_n()
}

fn test_attached_native_threads_keep_what_they_hold() {
	bad, fresh, again := run(1)
	assert fresh == vna_n // each attach registered its thread
	assert again == vna_n // a second attach is a no-op
	assert bad == 0
}

fn test_detach_then_new_native_threads_attach_and_hold() {
	bad1, _, _ := run(2) // these threads detach before they exit
	assert bad1 == 0
	bad2, fresh, _ := run(1) // the released slots serve new threads
	assert fresh == vna_n
	assert bad2 == 0
}

fn test_a_pinned_buffer_in_unscanned_memory_survives() {
	b := unsafe { malloc(vna_len) }
	unsafe { vmemset(b, 0x77, vna_len) }
	C.vna_park(b)
	unsafe {
		b = nil
	}
	_ = scrub_stack()
	keep := churn()
	assert keep.len > 0
	assert C.vna_parked_bad(0x77) == 0
	C.vna_unpark()
}

fn test_gate_abi_and_safe_region_entry_points() {
	b := unsafe { malloc(vna_len) }
	C.vna_gate(b)
	assert C.vna_abi() == 1
	C.vna_safe_roundtrip()
	gc_collect()
}

// a native loop that polls at its back-edge parks at the stop: it sees the
// stop flag raised (the cooperative park, not only the suspend fallback), and
// every collection completes while it spins
// collections while an attached native thread spins: 10 timed, then (polling)
// more until the loop has seen a stop, at most 200 (a loaded box can keep the
// spinner off-CPU through a few short stops)
fn spin_and_collect(poll int) (int, time.Duration) {
	C.vna_poll_start(poll)
	for C.vna_poll_live_n() == 0 {
		time.sleep(time.millisecond)
	}
	sw := time.new_stopwatch()
	for _ in 0 .. 10 {
		gc_collect()
	}
	took := sw.elapsed()
	if poll == 1 {
		for _ in 0 .. 190 {
			if C.vna_poll_seen_so_far() > 0 {
				break
			}
			gc_collect()
			time.sleep(100 * time.microsecond)
		}
	}
	return C.vna_poll_finish(), took
}

fn test_a_polling_native_loop_parks_at_the_stop() {
	seen, took := spin_and_collect(1)
	assert seen > 0
	_, took0 := spin_and_collect(0) // no poll: each stop suspends the loop after the bounded wait
	eprintln('native loop, 10 collections: polling ${took}, not polling ${took0}')
}

fn test_unattached_native_threads_lose_what_they_hold_red_witness() {
	if os.getenv('VNA_RED') != '1' {
		return
	}
	bad, _, _ := run(0)
	eprintln('VNA_RED: unattached native threads: ${bad}/${vna_n} buffers read wrong')
	assert bad > 0
}
