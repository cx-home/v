// array_wait.v — the program vgc_young_array_wait_test.v builds (cx-core-code#279).
// `ts.wait()` on a []thread Part allocates the answer array, then joins the
// threads in order and stores each result into the array's buffer. Here thread
// 0 churns (minor cycles) only after the main thread is inside the wait, so
// the answer array, allocated before the join, survives a minor and is old
// (sticky); thread 0 then builds its result of fresh (young) arrays and
// returns. The waiter stores that result into the old buffer, and the main
// thread churns again (more minors) before it reads the answers and checks
// every value. bad = results whose values changed.
import os
import time
import sync.stdatomic

struct Part {
	counts []int
	sums   []i64
	name   string
}

fn churn(mb int) int {
	mut s := 0
	for _ in 0 .. mb * 1024 {
		b := []u8{len: 1000, init: u8(s)}
		s += b[999]
		// the size of a result's arrays, filled: a swept one handed out again reads changed
		w := []i64{len: 512, init: 0x7777}
		s += int(w[511] & 1)
		mut chain := &Node(unsafe { nil })
		for _ in 0 .. 4 {
			chain = &Node{
				next: chain
			}
		}
		s += int(chain.pad[0])
	}
	return s
}

struct Node {
	next &Node = unsafe { nil }
	pad  [6]u64
}

fn part(id int, n int) Part {
	mut counts := []int{len: n}
	mut sums := []i64{len: n}
	for i in 0 .. n {
		counts[i] = id + i
		sums[i] = i64(id) * 1000 + i64(i)
	}
	return Part{
		counts: counts
		sums:   sums
		name:   'part-${id}'
	}
}

// the first worker: it waits until the main thread is inside ts.wait() (the
// answer array allocated, the join of this thread blocked), churns, then
// builds its result
fn first(n int, entered &u64) Part {
	for stdatomic.load_u64(entered) == 0 {
		time.sleep(100 * time.microsecond)
	}
	time.sleep(2 * time.millisecond)
	_ := churn(4)
	return part(0, n)
}

fn later(id int, n int) Part {
	return part(id, n)
}

fn check(parts []Part, n int) int {
	mut bad := 0
	for id, p in parts {
		if p.name != 'part-${id}' || p.counts.len != n || p.sums.len != n {
			bad++
			continue
		}
		for i in 0 .. n {
			if p.counts[i] != id + i || p.sums[i] != i64(id) * 1000 + i64(i) {
				bad++
				break
			}
		}
	}
	return bad
}

fn main() {
	workers := os.getenv_opt('WORKERS') or { '4' }.int()
	rounds := os.getenv_opt('ROUNDS') or { '20' }.int()
	n := 512
	mut bad := 0
	for _ in 0 .. rounds {
		mut entered := u64(0)
		mut ts := []thread Part{cap: workers}
		ts << spawn first(n, &entered)
		for id in 1 .. workers {
			ts << spawn later(id, n)
		}
		stdatomic.store_u64(&entered, 1)
		parts := ts.wait()
		_ := churn(8)
		bad += check(parts, n)
	}
	println('done bad=${bad} rounds=${rounds} workers=${workers} minors=${vgc_minor_cycles_count()}')
}
