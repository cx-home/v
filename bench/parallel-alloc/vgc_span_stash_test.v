// vgc_span_stash_test.v — cx-private#1910: a registered thread refills its span
// cache from its own stash (VGC_Cache.tpool) and takes free_spans_lock once per
// batch, not once per span. Eight threads each keep a rolling window of 2048
// pointer-bearing records alive while a ninth forces a collection every 400 refills:
// every window is re-verified after each refill (soundness: a stashed span
// handed out twice, or swept while stashed, corrupts a record), and over the
// steady phase the share of refills that took the pool lock is asserted below
// 60 % (before the stash every refill took it: 100 %).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_span_stash_test.v
module main

import time
import sync.stdatomic

@[heap]
struct Rec {
mut:
	a    u64
	b    u64
	next &Rec = unsafe { nil }
	sum  u64
}

const window = 2048
const threads = 8
const steps = 400000

fn mk(i u64, prev &Rec) &Rec {
	r := &Rec{
		a:    i
		b:    i * 7919
		next: prev
		sum:  i + i * 7919
	}
	return r
}

fn worker(id u64, done &Done) u64 {
	mut ring := []&Rec{len: window}
	mut bad := u64(0)
	mut prev := &Rec(unsafe { nil })
	for i in u64(0) .. u64(steps) {
		r := mk(i + id * 1000000, prev)
		slot := int(i % u64(window))
		ring[slot] = r
		prev = r
		if slot == 0 {
			// one full window is live: verify every record and its predecessor link
			for k in 0 .. window {
				x := ring[k]
				if x == unsafe { nil } {
					continue
				}
				if x.sum != x.a + x.b {
					bad++
				}
				if x.next != unsafe { nil } && x.next.sum != x.next.a + x.next.b {
					bad++
				}
			}
			prev = unsafe { nil }
		}
	}
	stdatomic.add_u64(&done.n, 1)
	return bad
}

// The collection cadence is paced by the workers' refills, not by the clock:
// every stop drains every thread's stash, so the share of refills that took
// the lock depends on how many refills a thread makes between stops. A 3 ms
// clock gave ~15 per thread per cycle on a loaded 4-vCPU runner (FreeBSD CI
// 38184127117: 68 %) against hundreds on a quiet box; a cycle now waits for
// cycle_refills refills across the workers (at most cycle_wait).
//
// cx-home/v#40: the 20 ms cap on that wait still made the cadence a clock on a
// slow runner — FreeBSD's 4-vCPU runner under VJOBS=1 with eight walkers made
// ~125 refills per cycle (12,461 over 100 stops, share 71-73 %). The wait is
// now on the refills alone; it ends early only when every worker has finished
// (Done), so no stop lands between two of a thread's refills because
// a clock ran out.
const cycle_refills = u64(400)

// how many workers of the running phase have finished
@[heap]
struct Done {
mut:
	n u64
}

fn collector(n int, done &Done) u64 {
	for _ in 0 .. n {
		if stdatomic.load_u64(&done.n) >= u64(threads) {
			break
		}
		gc_collect()
		$if vgc ? {
			base, _ := vgc_pool_refill_stats()
			for stdatomic.load_u64(&done.n) < u64(threads) {
				time.sleep(time.millisecond)
				r, _ := vgc_pool_refill_stats()
				if r - base >= cycle_refills {
					break
				}
			}
		} $else {
			time.sleep(3 * time.millisecond)
		}
	}
	return 0
}

fn run_phase() u64 {
	done := &Done{}
	mut ts := []thread u64{}
	for t in 0 .. threads {
		ts << spawn worker(u64(t) + 1, done)
	}
	ts << spawn collector(100, done)
	mut bad := u64(0)
	for t in ts {
		bad += t.wait()
	}
	return bad
}

fn test_span_stash_refills_without_the_pool_lock() {
	// warm-up: the heap grows to its working set (every refill carves or takes
	// the lock here, by design)
	assert run_phase() == 0
	$if vgc ? {
		refills0, takes0 := vgc_pool_refill_stats()
		bad := run_phase()
		assert bad == 0, 'corrupted records: ${bad}'
		refills1, takes1 := vgc_pool_refill_stats()
		refills := refills1 - refills0
		takes := takes1 - takes0
		println('steady phase: refills=${refills} lock_takes=${takes} share=${f64(takes) * 100.0 / f64(if refills > 0 {
			refills
		} else {
			u64(1)
		}):.1f}%')
		assert refills > 1000, 'too few refills to judge: ${refills}'
		assert takes * 10 < refills * 6, 'the pool lock was taken on ${takes} of ${refills} refills'
	} $else {
		assert run_phase() == 0
	}
}
