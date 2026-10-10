// vgc_fork_child_mark_test.v — a fork child collects and execs with the mark
// pool engaged in its parent, and a pool that grows after its first parallel
// cycle drains every cycle with its new threads (cx-home/v#16).
//
// The defect (cx-private release gate, 10-09): the fork child inherited the
// parent's mark generation (vgc_mark_go = G) while its pool counters were
// reset; the child's first parallel cycle recreated pool threads that started
// from generation 0, took G for a running cycle and counted themselves idle
// before the collector's reset of vgc_mark_idle, so the idle count never
// reached the marker count: every marker spun forever inside os.execve's
// array_push -> vgc_maybe_gc -> vgc_parallel_mark (seven extraction-gate
// shards hung 90 minutes). A pool growing from k to k+1 threads in one
// process had the same start.
//
// Shapes (each run in a watched child process, bounded by a timeout, so a
// regression is a failed assertion and never a hung test):
// fork:  four threads build a 12 MB graph and collect with eight markers
//        forced, then the process forks; the fork child allocates and
//        collects three times, checks its graph and execs /bin/sh -c 'exit 7'
//        through os.execve; the parent waits for exit status 7 for at most
//        60 s (a hang: SIGKILL and FORK-CHILD-HANG).
// grow:  a graph grows in steps with a collection after each, the marker
//        count planned from the previous mark's work (VGC_MARK_PAR_MIN_US=300),
//        so the pool starts small and grows (dev2: 4 markers, then 8); the
//        run must finish inside its limit with the checksum holding and the
//        pool engaged. How far the count moves depends on the box (the plan
//        caps it at the core count and halves it when parallel cycles do not
//        pay), so the trace's counts are printed, not asserted.
//
// Run: ./v test bench/parallel-alloc/vgc_fork_child_mark_test.v
module main

import os
import sync
import time

@[heap]
struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

const node_bytes = 48
const nthreads = 4

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

fn build(id int, mut wg sync.WaitGroup, mut heads []&Node) {
	heads[id] = chain(id, 12 * 1024 * 1024 / node_bytes / nthreads)
	wg.done()
}

fn fork_main() {
	mut heads := []&Node{len: nthreads, init: unsafe { nil }}
	mut wg := sync.new_waitgroup()
	wg.add(nthreads)
	for t in 0 .. nthreads {
		spawn build(t, mut wg, mut heads)
	}
	wg.wait()
	for _ in 0 .. 3 {
		gc_collect()
	}
	mut before := u64(0)
	for h in heads {
		before += sum_chain(h)
	}
	pid := os.fork()
	if pid == 0 {
		// the fork child: allocate past a trigger, collect, check, exec
		mut mine := []&Node{}
		for k in 0 .. 8 {
			mine << chain(100 + k, 20000)
		}
		for _ in 0 .. 3 {
			gc_collect()
		}
		mut s := u64(0)
		for h in heads {
			s += sum_chain(h)
		}
		for h in mine {
			_ = sum_chain(h)
		}
		if s != before {
			C._exit(6)
		}
		os.execve('/bin/sh', ['-c', 'exit 7'], []string{}) or { C._exit(5) }
		C._exit(5)
	}
	assert pid > 0
	mut status := 0
	deadline := time.now().add(60 * time.second)
	for {
		r := C.waitpid(pid, &status, 1) // WNOHANG
		if r == pid {
			break
		}
		if time.now() > deadline {
			C.kill(pid, 9)
			C.waitpid(pid, &status, 0)
			println('FORK-CHILD-HANG')
			exit(4)
		}
		time.sleep(20 * time.millisecond)
	}
	code := (status >> 8) & 0xff
	println('FORK-CHILD-EXIT=${code} status=${status} cycles=${gc_cycles()}')
}

fn grow_main() {
	mut heads := []&Node{}
	mut want := u64(0)
	for step in 0 .. 24 {
		heads << chain(step, 6000 * (step + 1))
		gc_collect()
	}
	for i, h in heads {
		_ = i
		want += sum_chain(h)
	}
	gc_collect()
	mut got := u64(0)
	for h in heads {
		got += sum_chain(h)
	}
	assert got == want
	println('GROW-OK=${got} cycles=${gc_cycles()}')
}

// run the child shape `which` under env, killed after limit_s; its output
fn watched(which string, env map[string]string, limit_s int) (int, string) {
	log := os.join_path(os.temp_dir(), 'vgc_fork_child_mark_${which}_${os.getpid()}.log')
	mut p := os.new_process('/bin/sh')
	p.set_args(['-c', 'exec "\$0" > "\$1" 2>&1', os.executable(), log])
	mut e := os.environ()
	e['VGC_FK_CHILD'] = which
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

fn marker_counts(out string) map[string]bool {
	mut m := map[string]bool{}
	for l in out.split_into_lines() {
		if l.contains('markers=') {
			c := l.all_after('markers=').all_before(' ')
			if c != '1' {
				m[c] = true
			}
		}
	}
	return m
}

fn test_fork_child_collects_and_execs() {
	which := os.getenv('VGC_FK_CHILD')
	if which == 'fork' {
		fork_main()
		return
	}
	if which == 'grow' {
		grow_main()
		return
	}
	if which != '' {
		return
	}
	code, out := watched('fork', {
		'VGC_MARK_WORKERS':    '8'
		'VGC_MARK_PAR_MIN_US': '0'
	}, 120)
	tail := out.split_into_lines().filter(!it.starts_with('vgc')).join('\n')
	println('vgc_fork_child_mark: fork shape exit=${code}: ${tail}')
	assert code == 0, out
	assert out.contains('FORK-CHILD-EXIT=7'), out
	assert out.contains('markers=8'), 'the parent pool did not engage:\n${out}'
}

fn test_growing_pool_drains_every_cycle() {
	if os.getenv('VGC_FK_CHILD') != '' {
		return
	}
	code, out := watched('grow', {
		'VGC_MARK_WORKERS':    '8'
		'VGC_MARK_PAR_MIN_US': '300'
	}, 180)
	counts := marker_counts(out)
	println('vgc_fork_child_mark: grow shape exit=${code}, parallel marker counts ${counts.keys()}')
	assert code == 0, out
	assert out.contains('GROW-OK='), out
	assert counts.len >= 1, 'the pool never engaged (no parallel marker count in the trace):\n${out}'
}
