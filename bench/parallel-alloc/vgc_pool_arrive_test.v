// vgc_pool_arrive_test.v — a pool thread created for a cycle has ARRIVED before
// the world stops (cx-home/v#68).
//
// vgc_mark_plan / vgc_walk_plan grow the mark pool just before the stop, and
// vgc_pool_run's join counts every created pool thread. pthread_create returns
// before the thread runs, and a start can need a lock a mutator holds: on the
// sanitizer build ASan's thread registry, which its pthread_create and
// thread-exit hooks lock and the new thread's start locks too. With that
// mutator stopped, the thread never started and the join spun for good: the
// concurrency soundness gate's workers4_20k ran 18 min at 99 % of a core
// (dev2, 11-10, cx-private#2021's pair), the collector in vgc_pool_run, both
// arrived markers asleep, two threads on ASan's lock.
//
// The hook VGC_TEST_POOL_ARRIVE=1 stands in for that lock: a starting pool
// thread arrives only while vgc_test_lock is free, and a mutator thread holds
// it ~200 us at a time. The child collects with a four-marker pool; on a
// collector that stops the world with a pool thread not yet arrived, the stop
// catches the mutator holding the lock, the join waits on a thread that waits
// on the lock, and the parent kills the child at the limit.
//
// Run: ./v test bench/parallel-alloc/vgc_pool_arrive_test.v
module main

import os
import time

@[heap]
struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

fn chain(id int, n int) &Node {
	mut head := &Node(unsafe { nil })
	for i in 0 .. n {
		mut x := &Node{
			next: head
		}
		x.pad[0] = u64(id)
		x.pad[1] = u64(i)
		x.pad[2] = u64(id) * 1000003 + u64(i) * 7
		head = x
	}
	return head
}

fn sum_chain(h &Node) u64 {
	mut s := u64(0)
	mut n := unsafe { h }
	for n != unsafe { nil } {
		if n.pad[2] != n.pad[0] * 1000003 + n.pad[1] * 7 {
			println('BAD node ${n.pad[0]} ${n.pad[1]}')
			exit(3)
		}
		s += n.pad[2]
		n = n.next
	}
	return s
}

@[heap]
struct Stop {
mut:
	done bool
}

// holds the hook's lock ~200 us at a time and lets go for a moment between: a
// pool thread started just before a stop finds it held, and a stop that catches
// this thread keeps it held
fn ticker(mut st Stop) {
	for !st.done {
		vgc_test_lock_hold()
		t0 := time.sys_mono_now()
		for time.sys_mono_now() - t0 < 200_000 {
		}
		vgc_test_lock_release()
		t1 := time.sys_mono_now()
		for time.sys_mono_now() - t1 < 2_000 {
		}
	}
	vgc_test_lock_release()
}

fn arrive_main() {
	mut st := &Stop{}
	t := spawn ticker(mut st)
	mut heads := []&Node{}
	mut want := u64(0)
	for step in 0 .. 16 {
		heads << chain(step, 4000 * (step + 1))
		gc_collect()
	}
	for h in heads {
		want += sum_chain(h)
	}
	gc_collect()
	mut got := u64(0)
	for h in heads {
		got += sum_chain(h)
	}
	st.done = true
	t.wait()
	assert got == want
	println('ARRIVE-OK=${got} cycles=${gc_cycles()}')
}

fn watched(env map[string]string, limit_s int) (int, string) {
	log := os.join_path(os.temp_dir(), 'vgc_pool_arrive_${os.getpid()}.log')
	mut p := os.new_process('/bin/sh')
	p.set_args(['-c', 'exec "\$0" > "\$1" 2>&1', os.executable(), log])
	mut e := os.environ()
	e['VGC_PA_CHILD'] = '1'
	e['VGC_GCTRACE'] = '2'
	for k, v in env {
		e[k] = v
	}
	p.set_environment(e)
	p.run()
	deadline := time.now().add(limit_s * time.second)
	mut killed := false
	for p.is_alive() {
		if time.now() > deadline {
			p.signal_kill()
			killed = true
			break
		}
		time.sleep(20 * time.millisecond)
	}
	p.wait()
	code := if killed { -9 } else { p.code }
	p.close()
	mut out := os.read_file(log) or { '' }
	os.rm(log) or {}
	if killed {
		out += '\n<killed after ${limit_s} s>'
	}
	return code, out
}

fn test_pool_threads_arrive_before_the_stop() {
	if os.getenv('VGC_PA_CHILD') != '' {
		arrive_main()
		return
	}
	code, out := watched({
		'VGC_TEST_POOL_ARRIVE': '1'
		'VGC_MARK_WORKERS':     '4'
		'VGC_MARK_PAR_MIN_US':  '0'
		'VGC_WALK_LOAD_GATE':   '0'
	}, 60)
	mut parallel := false
	for l in out.split_into_lines() {
		if l.contains('markers=') && !l.contains('markers=1 ') {
			parallel = true
		}
	}
	tail := out.split_into_lines().filter(!it.starts_with('vgc')).join('\n')
	println('vgc_pool_arrive: exit=${code} parallel=${parallel}: ${tail}')
	assert code == 0, out
	assert out.contains('ARRIVE-OK='), out
	assert parallel, 'the pool never engaged (no parallel marker count in the trace):\n${out}'
}
