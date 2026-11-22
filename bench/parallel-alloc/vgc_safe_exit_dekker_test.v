// vgc_safe_exit_dekker_test.v — the GC-safe region's exit handshake and the
// collector's stop are a Dekker pair (cx-private#2079).
//
// A thread leaving a safe region stores safe=0, then loads gc_stop_flag
// (vgc_safe_exit_publish); the collector stores gc_stop_flag=1, then loads each
// thread's safe word (vgc_stop_flag_raise, then the loads). The handshake is
// sound only if at least one side sees the other's store: either the collector
// reads safe==0 (and suspends the thread as a straggler) or the thread reads
// gc_stop_flag==1 (and waits until the world resumes). The outcome where the
// thread reads gc_stop_flag==0 AND the collector reads safe==1 lets the thread
// run through mark and sweep unscanned: an object it allocates then is not
// marked and the sweep frees it while it is live. A store then a load of
// another word needs a full fence between them for that (store->load order);
// a release store and an acquire load do not give it (arm64: STLR then LDAPR;
// x86-64: a plain store then a plain load).
//
// cx-private#2079: `cx build --native` of bench/pivots/h2o/g1q6.cx died with
// SIGSEGV/SIGBUS in about 1 run in 30 — fa_range_groups' `parts` array (the
// join of its [par] scan workers' results, allocated as the main thread left a
// join's safe region) was swept while live and its slot handed to the next
// array, whose ints then read as a pointer.
//
// The test runs the two sides' own helpers (vgc_platform.h) on two threads,
// many rounds, and counts the rounds where both read the other's old value.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_safe_exit_dekker_test.v
module main

const rounds = 2_000_000

fn C.vgc_safe_exit_publish(my_safe &u32, stop_flag &u32) u32
fn C.vgc_stop_flag_raise(stop_flag &u32)
fn C.vgc_atomic_load_u32(p &u32) u32
fn C.vgc_atomic_store_u32(p &u32, v u32)
fn C.vgc_cpu_pause()

struct Dekker {
mut:
	// the four words on separate cache lines
	safe u32
	pad1 [31]u32
	flag u32
	pad2 [31]u32
	go   u32
	pad3 [31]u32
	done u32
	pad4 [31]u32
	// the collector's read of safe
	r_safe u32
}

// collector side: raise the stop flag, then read the thread's safe word
fn collector(mut d Dekker) {
	for r in 1 .. rounds + 1 {
		for C.vgc_atomic_load_u32(&d.go) != u32(r) {
		}
		C.vgc_stop_flag_raise(&d.flag)
		v := C.vgc_atomic_load_u32(&d.safe)
		d.r_safe = v
		C.vgc_atomic_store_u32(&d.done, u32(2 * r - 1))
		for C.vgc_atomic_load_u32(&d.done) != u32(2 * r) {
		}
	}
}

fn test_safe_exit_and_stop_flag_see_each_other() {
	mut d := &Dekker{}
	t := spawn collector(mut d)
	mut both_stale := 0
	for r in 1 .. rounds + 1 {
		// a thread in its safe region; no stop raised
		C.vgc_atomic_store_u32(&d.safe, 1)
		C.vgc_atomic_store_u32(&d.flag, 0)
		C.vgc_atomic_store_u32(&d.go, u32(r))
		// exiting side: publish safe=0, then read the stop flag
		f := C.vgc_safe_exit_publish(&d.safe, &d.flag)
		for C.vgc_atomic_load_u32(&d.done) != u32(2 * r - 1) {
		}
		if f == 0 && d.r_safe == 1 {
			both_stale++
		}
		C.vgc_atomic_store_u32(&d.done, u32(2 * r))
	}
	t.wait()
	println('rounds ${rounds}: both sides read the other old ${both_stale} times')
	assert both_stale == 0
}
