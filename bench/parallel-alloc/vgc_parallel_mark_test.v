// vgc_parallel_mark_test.v — the parallel marker reaches the same closure as
// one marker, and engages (cx-home/v#16).
//
// Shape: four threads each build a 12 MB graph of 48-byte nodes — a linked
// list whose nodes also point into a shared ring (cross-thread edges) — then
// the child collects three times with every marker forced on
// (VGC_MARK_PAR_MIN_US=0 VGC_MARK_WORKERS=8), walks every list and every ring
// slot and prints a checksum over the nodes' payloads. The single-marker run
// (VGC_MARK_WORKERS=1) must print the same checksum, both must exit 0 (a lost
// mark bit is a reclaimed-while-reachable node: a wrong checksum or a crash),
// and the parallel run's VGC_GCTRACE=2 phase lines must say markers=8.
//
// Run: ./v test bench/parallel-alloc/vgc_parallel_mark_test.v
module main

import os
import sync
import time

@[heap]
struct Node {
mut:
	next  &Node = unsafe { nil }
	cross &Node = unsafe { nil }
	pad   [3]u64
}

const node_bytes = 48
const per_thread_bytes = 12 * 1024 * 1024
const nthreads = 4
const ring_len = 4096

struct Shared {
mut:
	ring  []&Node
	lock  &sync.Mutex = sync.new_mutex()
	heads []&Node
}

fn build(id int, mut wg sync.WaitGroup, mut sh Shared) {
	mut head := &Node(unsafe { nil })
	for i in 0 .. per_thread_bytes / node_bytes {
		mut n := &Node{
			next: head
		}
		n.pad[0] = u64(id)
		n.pad[1] = u64(i)
		n.pad[2] = u64(id) * 1000003 + u64(i) * 7
		if i % 61 == 0 {
			sh.lock.lock()
			slot := (id * 1009 + i) % ring_len
			n.cross = sh.ring[slot]
			sh.ring[slot] = n
			sh.lock.unlock()
		}
		head = n
	}
	sh.heads[id] = head
	wg.done()
}

// The checksum is deterministic under any thread interleaving: the payload
// sum over every list node, the number of cross edges (the set of ring slots
// touched is fixed by (thread, index)) and the number of nodes reachable
// through the rings; every node reached is checked against its payload
// invariant, so a reclaimed-while-reachable node is a wrong sum, a BAD line or
// a crash.
fn checksum(sh &Shared) u64 {
	mut sum := u64(0)
	mut cross := u64(0)
	for h in sh.heads {
		mut n := h
		for n != unsafe { nil } {
			if n.pad[2] != n.pad[0] * 1000003 + n.pad[1] * 7 {
				println('BAD node ${n.pad[0]} ${n.pad[1]}')
				exit(3)
			}
			sum += n.pad[2]
			if n.cross != unsafe { nil } {
				c := n.cross
				if c.pad[2] != c.pad[0] * 1000003 + c.pad[1] * 7 {
					println('BAD cross ${c.pad[0]} ${c.pad[1]}')
					exit(3)
				}
				cross++
			}
			n = n.next
		}
	}
	mut via_ring := u64(0)
	for r in sh.ring {
		mut n := r
		for n != unsafe { nil } {
			if n.pad[2] != n.pad[0] * 1000003 + n.pad[1] * 7 {
				println('BAD ring ${n.pad[0]} ${n.pad[1]}')
				exit(3)
			}
			via_ring++
			n = n.cross
		}
	}
	return sum + cross * 1000000007 + via_ring * 998244353
}

fn child() {
	// cx-home/v#28 (fix/fable-v116 CI 38065594231): on Linux and FreeBSD this
	// child did not finish within the job's timeout, and os.execute holds its
	// output until it exits — a watchdog turns a hang into a failed run whose
	// captured output (the collector's own diagnostics included) the test
	// prints.
	spawn fn () {
		time.sleep(90 * time.second)
		eprintln('vgc_parallel_mark child: no progress in 90 s')
		exit(3)
	}()
	mut sh := &Shared{
		ring:  []&Node{len: ring_len, init: unsafe { nil }}
		heads: []&Node{len: nthreads, init: unsafe { nil }}
	}
	mut wg := sync.new_waitgroup()
	wg.add(nthreads)
	for t in 0 .. nthreads {
		spawn build(t, mut wg, mut sh)
	}
	wg.wait()
	for _ in 0 .. 3 {
		gc_collect()
	}
	// churn past the live set, then collect again: the marked set must survive
	mut sink := u64(0)
	for i in 0 .. 4096 {
		t := []u8{len: 4096, init: u8(i)}
		sink += t[i % 4096]
	}
	gc_collect()
	println('CHECK=${checksum(sh)} sink=${sink} cycles=${gc_cycles()}')
}

fn run(env string) (string, string) {
	r := os.execute('VGC_PM_CHILD=1 VGC_GCTRACE=2 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	mut check := ''
	for l in r.output.split_into_lines() {
		if l.starts_with('CHECK=') {
			check = l.all_after('CHECK=').all_before(' ')
		}
	}
	assert check != '', r.output
	return check, r.output
}

fn test_parallel_mark_reaches_the_same_closure() {
	if os.getenv('VGC_PM_CHILD') != '' {
		child()
		return
	}
	one, _ := run('VGC_MARK_WORKERS=1 ')
	par, out := run('VGC_MARK_PAR_MIN_US=0 VGC_MARK_WORKERS=8 ')
	println('vgc_parallel_mark: one marker CHECK=${one}, eight markers CHECK=${par}')
	assert one == par, 'the parallel marker reached a different closure: ${one} against ${par}'
	assert out.contains('markers=8'), 'the pool did not engage (no markers=8 phase line):\n${out}'
}
