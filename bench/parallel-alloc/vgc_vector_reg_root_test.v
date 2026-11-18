// vgc_vector_reg_root_test.v — an object whose only reference sits in a suspended thread's
// VECTOR register survives a collection (cx-home/cx-core-code#282).
//
// On darwin x86-64 the stop-the-world capture recorded only the 15 general registers of a
// suspended thread (thirdparty/vgc/vgc_platform.h, the mach path and the signal path), while
// darwin arm64 records the 64 NEON lanes and Windows x86-64 the XMM registers. clang copies a
// 16-byte V `string` ({ptr, len}) through one XMM register and libsystem's memmove uses YMM, so
// a thread suspended between such a load and its store held the only reference in a register
// the collector never read: the buffer was freed and reused while live. cx on ardec-dev3 read
// variable names that were other strings (`$d736ac`, `$__cx_seq__`, `$stdout`), 1 run in 3 with
// collections on, 0 in 9 with them off.
//
// Shape: a holder thread gets a 1 MB buffer's address only disguised (addr ^ mask; the @[noinline]
// maker's frame is gone and a scrub zeroes where it was), and vgc_vr_hold (vgc_vector_reg_root.h)
// unmasks it into xmm7 / v7 in one asm block, zeroes the general registers and spins. While the four
// holders spin, main collects twice and reads the live heap: the four buffers are live (held), so the
// live heap must stay >= 3 MB above where it was before they were made. A collector blind to vector
// registers frees them (the heap falls back); the control case (the address kept only disguised, so
// nothing holds it) shows that the measure sees a freed buffer. Several rounds.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_vector_reg_root_test.v
module main

#include "@DIR/vgc_vector_reg_root.h"

fn C.vgc_vr_hold(disguised u64, mask u64, started &i32, stop &i32) u64

const mask = u64(0x5a5a_a5a5_3c3c_c3c3)
const buf_len = 1024 * 1024
const holders = 4

@[heap]
struct Gate {
mut:
	started i32
	stop    i32
	back    u64
}

@[noinline]
fn make_disguised() u64 {
	b := []u8{len: buf_len, init: 3}
	return u64(voidptr(b.data)) ^ mask
}

// scrub: zero a wide frame below the caller, so no dead slot of make_disguised's frame (which
// held the plain address) is left where vgc_vr_hold's frame will sit and the stack scan reads.
@[noinline]
fn scrub() u64 {
	mut a := [512]u64{}
	for i in 0 .. 512 {
		a[i] = 0
	}
	return a[511]
}

@[noinline]
fn holder(mut g Gate) {
	d := make_disguised()
	_ = scrub()
	g.back = C.vgc_vr_hold(d, mask, &g.started, &g.stop)
}

// control: the same, but nothing holds the address (only its disguise, in the heap Gate)
@[noinline]
fn no_holder(mut g Gate) {
	d := make_disguised()
	_ = scrub()
	g.back = d
	g.started = 1
	for g.stop == 0 {
	}
}

fn live() u64 {
	gc_collect()
	gc_collect()
	return u64(gc_heap_usage().total_bytes)
}

fn held_growth(hold bool) u64 {
	l0 := live()
	mut gates := []&Gate{}
	mut ths := []thread{}
	for _ in 0 .. holders {
		mut g := &Gate{}
		gates << g
		ths << if hold { spawn holder(mut g) } else { spawn no_holder(mut g) }
	}
	for g in gates {
		for g.started == 0 {
		}
	}
	l1 := live()
	for mut g in gates {
		g.stop = 1
	}
	ths.wait()
	return if l1 > l0 { l1 - l0 } else { u64(0) }
}

fn test_the_measure_sees_a_freed_buffer() {
	g := held_growth(false)
	eprintln('control (nothing holds them): live heap +${g}')
	assert g < 2 * buf_len, 'the control kept ${g} bytes: the measure cannot see a freed buffer'
}

fn test_buffers_held_only_in_vector_registers_stay_live() {
	mut worst := u64(-1)
	for round in 0 .. 6 {
		g := held_growth(true)
		if g < worst {
			worst = g
		}
		eprintln('round ${round}: ${holders} buffers held only in a vector register: live heap +${g}')
	}
	assert worst >= 3 * buf_len, 'buffers whose only reference was a suspended thread vector register were freed while live: the live heap rose only ${worst} bytes for ${holders} MB held'
}
