// cx-private#1923 §1 (json-codec 1 MB scaling at k >= 20): a thread waiting on the collector's held lock sleeps
// instead of spinning. vgc_mutex_lock's last tier called sched_yield in a loop, so every waiter of free_spans_lock
// stayed runnable and on the CPU while one thread held it; at k = 24 workers on 28 cores that was ~14 % of the
// program's CPU (an unstripped -O2 build sampled: swtch_pri under vgc_mutex_lock, two thirds of it under
// vgc_central_get_fresh's stash refills). The spec: four waiters on a lock held 200 ms spend under a tenth of
// their 800 ms of waiting on the CPU, and each one takes the lock once it is free.
//
//   ../../v -gc e test bench/parallel-alloc/vgc_mutex_wait_test.v
module main

import time

const waiters = 4
const hold_ms = 200

fn wait_once(lk &u32) u64 {
	c0 := vgc_selftest_thread_cpu_ns()
	vgc_mutex_selftest_lock(lk)
	vgc_mutex_selftest_unlock(lk)
	return vgc_selftest_thread_cpu_ns() - c0
}

fn test_a_waiter_on_a_held_collector_lock_sleeps() {
	lk := unsafe { &u32(C.calloc(1, 64)) }
	vgc_mutex_selftest_lock(lk)
	mut ts := []thread u64{}
	for _ in 0 .. waiters {
		ts << spawn wait_once(lk)
	}
	time.sleep(hold_ms * time.millisecond)
	vgc_mutex_selftest_unlock(lk)
	mut cpu := u64(0)
	for t in ts {
		cpu += t.wait()
	}
	budget := u64(waiters * hold_ms) * 1_000_000 / 10
	assert cpu < budget, '${waiters} waiters on a lock held ${hold_ms} ms spent ${cpu / 1_000_000} ms on the CPU (budget ${budget / 1_000_000} ms)'
	assert unsafe { *lk } == 0
}
