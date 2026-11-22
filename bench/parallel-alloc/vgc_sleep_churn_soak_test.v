// vgc_sleep_churn_soak_test.v — cx-private#2078: the store's answer-thread
// pattern under back-to-back collections, without cx. Hundreds of short-lived
// threads a second each allocate a little, poll with a few 200 us time.sleep
// calls (a GC-safe region) and a time.now deadline check, and exit, while
// another thread runs collections back to back. A thread the stop-the-world
// suspends and never resumes stays in its sleep for good: the watchdog reports
// any live thread whose current sleep has run past 1 s (and ends the run after
// 10 s of that, since its join would never return), and every thread must join.
//
// Run: VGC_SOAK_S=600 ./v -gc e test bench/parallel-alloc/vgc_sleep_churn_soak_test.v
// (VGC_SOAK_S defaults to 20 s; VGC_SOAK_RATE threads a second, default 500.)
module main

import os
import time
import sync.stdatomic

const soak_slots = 8192

@[heap]
struct Soak {
mut:
	beat     []i64 // per slot: the monotonic ns its current sleep began, 0 = idle
	overruns u64   // sleeps that took more than 1 s
	finished u64
	cycles   u64
	stuck    u64 // watchdog: largest count of threads seen stuck at once
	stop     i64
}

fn soak_worker(mut s Soak, slot int, sleeps int) {
	mut keep := []string{}
	deadline := time.now().add(5 * time.second)
	for i in 0 .. sleeps {
		keep << 'answer ${slot} ${i}'
		if time.now() > deadline {
			break
		}
		t0 := i64(time.sys_mono_now())
		unsafe { stdatomic.store_i64(&s.beat[slot], t0) }
		time.sleep(200 * time.microsecond)
		if i64(time.sys_mono_now()) - t0 > i64(time.second) {
			stdatomic.add_u64(&s.overruns, 1)
		}
	}
	unsafe { stdatomic.store_i64(&s.beat[slot], 0) }
	if keep.len > 0 {
		stdatomic.add_u64(&s.finished, 1)
	}
}

fn soak_collector(mut s Soak) {
	for stdatomic.load_i64(&s.stop) == 0 {
		gc_collect()
		stdatomic.add_u64(&s.cycles, 1)
	}
}

fn soak_watchdog(mut s Soak) {
	mut stuck_since := i64(0)
	for stdatomic.load_i64(&s.stop) == 0 {
		time.sleep(100 * time.millisecond)
		now := i64(time.sys_mono_now())
		mut n := u64(0)
		for i in 0 .. soak_slots {
			b := unsafe { stdatomic.load_i64(&s.beat[i]) }
			if b != 0 && now - b > i64(time.second) {
				n++
			}
		}
		if n > stdatomic.load_u64(&s.stuck) {
			stdatomic.store_u64(&s.stuck, n)
			eprintln('vgc_sleep_churn_soak: ${n} thread(s) in a sleep past 1 s')
		}
		if n == 0 {
			stuck_since = 0
		} else if stuck_since == 0 {
			stuck_since = now
		} else if now - stuck_since > 10 * i64(time.second) {
			eprintln('vgc_sleep_churn_soak: FAIL ${n} thread(s) held in time.sleep for 10 s (parked: their joins would never return)')
			exit(3)
		}
	}
}

fn test_short_lived_sleepers_never_park_under_back_to_back_collections() {
	$if vgc ? {
		secs := os.getenv_opt('VGC_SOAK_S') or { '20' }.int()
		rate := os.getenv_opt('VGC_SOAK_RATE') or { '500' }.int()
		mut s := &Soak{
			beat: []i64{len: soak_slots}
		}
		col := spawn soak_collector(mut s)
		dog := spawn soak_watchdog(mut s)
		per_tick := if rate / 100 < 1 { 1 } else { rate / 100 } // a wave every 10 ms
		end := i64(time.sys_mono_now()) + i64(secs) * i64(time.second)
		mut spawned := u64(0)
		mut prev := []thread{}
		for i64(time.sys_mono_now()) < end {
			mut wave := []thread{cap: per_tick}
			for _ in 0 .. per_tick {
				slot := int(spawned % u64(soak_slots))
				wave << spawn soak_worker(mut s, slot, 3 + int(spawned % 6))
				spawned++
			}
			prev.wait()
			prev = wave.clone()
			time.sleep(10 * time.millisecond)
		}
		prev.wait()
		stdatomic.store_i64(&s.stop, 1)
		col.wait()
		dog.wait()
		finished := stdatomic.load_u64(&s.finished)
		overruns := stdatomic.load_u64(&s.overruns)
		cycles := stdatomic.load_u64(&s.cycles)
		println('vgc_sleep_churn_soak: secs=${secs} spawned=${spawned} joined=${finished} cycles=${cycles} overruns=${overruns} max_stuck=${stdatomic.load_u64(&s.stuck)}')
		assert cycles > 0
		assert finished == spawned, 'joined ${finished} of ${spawned}'
		assert overruns == 0, '${overruns} sleeps of 200 us took more than 1 s'
	}
}
