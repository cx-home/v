// vgc_span_stash_test.v — cx-private#1910: a registered thread refills its span
// cache from its own stash (VGC_Cache.tpool) and takes free_spans_lock once per
// batch, not once per span. Eight threads each keep a rolling window of 2048
// pointer-bearing records alive while a ninth forces a collection every 3 ms:
// every window is re-verified after each refill (soundness: a stashed span
// handed out twice, or swept while stashed, corrupts a record), and over the
// steady phase the share of refills that took the pool lock is asserted below
// 60 % (before the stash every refill took it: 100 %).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_span_stash_test.v
module main

import time

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

fn worker(id u64) u64 {
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
	return bad
}

fn collector(n int) u64 {
	for _ in 0 .. n {
		gc_collect()
		time.sleep(3 * time.millisecond)
	}
	return 0
}

fn run_phase() u64 {
	mut ts := []thread u64{}
	for t in 0 .. threads {
		ts << spawn worker(u64(t) + 1)
	}
	ts << spawn collector(100)
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
