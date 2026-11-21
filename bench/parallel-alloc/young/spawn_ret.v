// spawn_ret.v — the program vgc_young_spawn_ret_test.v builds (cx-home/v#80).
// WORKERS threads each churn garbage (minor cycles run while they work, so the
// thread wrapper's return box, allocated before the call, survives one and is
// old), then build a result of fresh (young) arrays and return it. The main
// thread waits until every worker has returned, churns again (more minors while
// the results sit in the boxes only), then joins and checks every value.
import os
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

fn work(id int, n int, done &u64) Part {
	_ := churn(4)
	mut counts := []int{len: n}
	mut sums := []i64{len: n}
	for i in 0 .. n {
		counts[i] = id + i
		sums[i] = i64(id) * 1000 + i64(i)
	}
	stdatomic.add_u64(done, 1)
	return Part{
		counts: counts
		sums:   sums
		name:   'part-${id}'
	}
}

fn main() {
	workers := os.getenv_opt('WORKERS') or { '8' }.int()
	rounds := os.getenv_opt('ROUNDS') or { '20' }.int()
	n := 512
	mut bad := 0
	for _ in 0 .. rounds {
		mut done := u64(0)
		mut ts := []thread Part{cap: workers}
		for id in 0 .. workers {
			ts << spawn work(id, n, &done)
		}
		for stdatomic.load_u64(&done) < u64(workers) {
			_ := churn(1)
		}
		_ := churn(8)
		parts := ts.wait()
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
	}
	println('done bad=${bad} rounds=${rounds} workers=${workers} minors=${vgc_minor_cycles_count()}')
}
