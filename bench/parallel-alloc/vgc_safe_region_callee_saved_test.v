// vgc_safe_region_callee_saved_test.v — a value a thread holds only in a
// callee-saved register across a GC-safe region survives the collections that
// run while it is blocked there (cx-private#2079).
//
// A thread in a safe region is not suspended: the collector takes its roots
// from the stack range and the register snapshot recorded at entry
// (vgc_safe_enter_spill). The snapshot was a setjmp inside
// vgc_safe_enter_spill after its own prologue had saved the caller's
// callee-saved registers into its frame and reused them for its arguments
// (arm64: x19..x24): the snapshot held the spill's arguments, and the
// caller's values sat in a frame that dies when the entry returns — the
// blocking call's frames (pthread_join's) open on it. A value the caller kept
// only in such a register was in no root, and the sweep freed it while live.
//
// cx-private#2079: `cx build --native` of bench/pivots/h2o/g1q6.cx died with
// SIGSEGV/SIGBUS about 1 run in 30 on pbm1 — fa_range_groups' join of its
// [par] scan workers (Array_thread_FaPart_wait, inlined) kept the result
// array in x19 across each pthread_join's safe region; the array was swept
// during the join, a worker's next array took its slot, and its ints were
// then read as the parts' table pointers.
//
// The test allocates a block, keeps its only reference in x19 (arm64) / rbx
// (x86-64) across a safe region whose blocking call overwrites the dead entry
// frames, while a second thread collects, then checks the block's alloc bit
// and its contents.
//
// Run: ./v -gc e -prod test bench/parallel-alloc/vgc_safe_region_callee_saved_test.v
// (-prod, as cx ships: at -O0 the spill keeps its arguments on its stack and
// leaves the callee-saved registers alone)
module main

#include "@DIR/vgc_safe_region_callee_saved.h"

fn C.srcs_hold(gop &u32, donep &u32) usize
fn C.srcs_intact(a usize) int

struct Flags {
mut:
	go   u32
	done u32
}

fn collector(mut f Flags) {
	for C.__atomic_load_n(&f.go, C.__ATOMIC_SEQ_CST) == 0 {
	}
	// collections while the holder is blocked, with churn between them so a
	// freed slot is taken again
	for _ in 0 .. 4 {
		mut junk := [][]u64{}
		for i in 0 .. 2000 {
			junk << []u64{len: 512, init: u64(i)}
		}
		gc_collect()
	}
	C.__atomic_store_n(&f.done, 1, C.__ATOMIC_SEQ_CST)
}

fn C.__atomic_load_n(p &u32, order int) u32
fn C.__atomic_store_n(p &u32, v u32, order int)

fn test_callee_saved_value_survives_a_safe_region() {
	mut freed := 0
	mut clobbered := 0
	for _ in 0 .. 5 {
		mut f := &Flags{}
		t := spawn collector(mut f)
		a := C.srcs_hold(&f.go, &f.done)
		t.wait()
		if vgc_addr_status(voidptr(a)) & 1 == 0 {
			freed++
		}
		if C.srcs_intact(a) == 0 {
			clobbered++
		}
	}
	println('5 rounds: block freed in ${freed}, contents clobbered in ${clobbered}')
	assert freed == 0
	assert clobbered == 0
}
