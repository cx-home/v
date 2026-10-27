// vgc_acct_flush_selftest — white-box check that the pacer sees several
// threads' allocation within a sixteenth of the cycle's budget each
// (cx-home/v#56): a thread folds its private accounting into heap_live once it
// has allocated vgc_acct_flush_cur bytes, and the pacer sets that to
// (goal - marked) / 16, at least 64 KB, at most 1 MB. With the fixed 1 MB, four
// threads could hold 4 MB the pacer had not seen against a 1 MB budget.
//
// The main thread holds 8 MB live, so the budget is a few MB and its sixteenth
// a few hundred KB. Four workers each allocate 512 KB of garbage in 64-byte
// objects (under the fixed 1 MB) and then poll without allocating; the main thread reads, with no
// collection between, how many bytes the workers hold unflushed. The bound is
// four times the threshold the formula gives for this cycle's budget. If a
// collection ran during the window (it folds every thread's deltas) the round
// is repeated, up to ten times.
//
// Driven by bench/parallel-alloc/vgc_acct_flush_test.v (module main). Only
// compiled under -d vgc / -gc e (the `_d_vgc` filename suffix).
//
// Return codes: 0 = ok
//   1 = precondition: main thread not vgc-registered
//   2 = the workers never finished their allocation
//   3 = every round saw a collection during the window
//   4 = the workers held more unflushed bytes than four budget sixteenths
module builtin

const vgc_aft_workers = 4
const vgc_aft_bytes = 512 * 1024

__global vgc_aft_done = u32(0)
__global vgc_aft_release = u32(0)
__global vgc_aft_round = u32(0)
__global vgc_aft_idx = [4]int{}
__global vgc_aft_sink = usize(0)

fn vgc_aft_worker(k int) {
	vgc_ensure_registered()
	vgc_aft_idx[k] = C.vgc_get_cache_idx()
	mut seen := u32(0)
	for C.vgc_atomic_load_u32(&vgc_aft_release) == 0 {
		r := C.vgc_atomic_load_u32(&vgc_aft_round)
		if r != seen {
			seen = r
			for _ in 0 .. vgc_aft_bytes / 64 {
				_ = unsafe { malloc_noscan(64) }
			}
			C.vgc_atomic_add_u32(&vgc_aft_done, 1)
		}
		vgc_native_poll_slow()
		C.vgc_cpu_pause()
	}
}

fn vgc_aft_w0() {
	vgc_aft_worker(0)
}

fn vgc_aft_w1() {
	vgc_aft_worker(1)
}

fn vgc_aft_w2() {
	vgc_aft_worker(2)
}

fn vgc_aft_w3() {
	vgc_aft_worker(3)
}

// vgc_acct_flush_selftest returns 0 when the workers' unflushed bytes stay
// within four budget sixteenths, else the failed check's code (file header).
pub fn vgc_acct_flush_selftest() u32 {
	if C.vgc_get_cache_idx() < 0 {
		return 1
	}
	live := unsafe { malloc_noscan(8 * 1024 * 1024) }
	vgc_force_collect()
	C.vgc_start_thread(vgc_aft_w0)
	C.vgc_start_thread(vgc_aft_w1)
	C.vgc_start_thread(vgc_aft_w2)
	C.vgc_start_thread(vgc_aft_w3)
	defer {
		C.vgc_atomic_store_u32(&vgc_aft_release, 1)
	}
	for round in u32(1) .. 11 {
		c0 := vgc_heap.gc_cycle
		d0 := C.vgc_atomic_load_u32(&vgc_aft_done)
		C.vgc_atomic_store_u32(&vgc_aft_round, round)
		mut spins := u64(0)
		for C.vgc_atomic_load_u32(&vgc_aft_done) < d0 + vgc_aft_workers {
			C.vgc_cpu_pause()
			spins++
			if spins > 10_000_000_000 {
				return 2
			}
		}
		mut unseen := u64(0)
		for k in 0 .. vgc_aft_workers {
			if vgc_aft_idx[k] >= 0 {
				unseen += unsafe { vgc_cache(vgc_aft_idx[k]).alloc_delta }
			}
		}
		if vgc_heap.gc_cycle != c0 {
			continue // a collection folded the deltas: not a reading
		}
		marked := C.vgc_atomic_load_u64(&vgc_heap.heap_marked)
		goal := C.vgc_atomic_load_u64(&vgc_heap.next_gc)
		mut each := if goal > marked { (goal - marked) / 16 } else { u64(0) }
		if each < u64(64) * 1024 {
			each = u64(64) * 1024
		}
		if unseen > u64(vgc_aft_workers) * each {
			C.printf(c'vgc_acct_flush_selftest: unseen %llu B against %d x %llu B (marked %llu, goal %llu)\n',
				unseen, vgc_aft_workers, each, marked, goal)
			return 4
		}
		vgc_aft_sink = usize(live)
		return 0
	}
	vgc_aft_sink = usize(live)
	return 3
}
