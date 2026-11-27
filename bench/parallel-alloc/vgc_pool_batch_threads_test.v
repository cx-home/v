// vgc_pool_batch_threads_test.v — with many allocating threads, a span refill
// takes the pool's one lock (free_spans_lock) for a batch that scales with the
// threads (https://github.com/cx-home/cx-private/issues/2040).
//
// The stash refill moved four 1- and 2-page spans per lock take at any thread
// count (cx-private#1910), so k threads that allocate fast took the one lock
// every ~32 KB each: on dev2 a pure-V loop that allocates small pointer nodes
// read 20 threads / 1 thread = 2.45x the CPU per unit (sys 1.7 s of 4.7, 50k
// involuntary switches) against 1.12x as 20 processes; sixteen times the batch
// 1.76x (sys 0.8 s), sixty-four times 1.58x (mc-2040e). cx's sql-roundtrips at
// [par 20] read 1.70x its k=1 CPU per statement against 1.05x as 20 processes.
// Bars:
//   - eight workers that allocate small pointer nodes take free_spans_lock on
//     at most one refill in ten (vgc_pool_refill_stats); the head took it
//     on one in seven (14,792 of 101,109);
//   - every node a worker kept reads back as built.
//
// Run: ./v test bench/parallel-alloc/vgc_pool_batch_threads_test.v
module main

struct Node {
	name string
	kids []&Node
	v    i64
}

const steps = 400000

fn worker(id int) int {
	mut keep := []&Node{len: 256, init: &Node{}}
	for i in 0 .. steps {
		k := [&Node{v: i}, &Node{v: i + 1}]
		n := &Node{name: 'w${id}', kids: k, v: i}
		keep[i % 256] = n
	}
	mut bad := 0
	for j, n in keep {
		i := steps - 256 + ((j - (steps - 256) % 256) + 256) % 256
		if n.v != i || n.kids.len != 2 || n.kids[1].v != i + 1 || n.name != 'w${id}' {
			bad++
		}
	}
	return bad
}

fn test_a_refill_takes_the_pool_lock_for_a_batch_that_scales_with_the_threads() {
	r0, t0 := vgc_pool_refill_stats()
	mut ths := []thread int{}
	for id in 0 .. 8 {
		ths << spawn worker(id)
	}
	mut bad := 0
	for t in ths {
		bad += t.wait()
	}
	r1, t1 := vgc_pool_refill_stats()
	refills := r1 - r0
	takes := t1 - t0
	eprintln('vgc_pool_batch_threads_test: ${refills} refills, ${takes} free_spans_lock takes')
	assert bad == 0, '${bad} kept nodes read back wrong'
	assert refills > 1000, 'only ${refills} refills: the workers did not allocate through the stash'
	assert takes * 10 <= refills, 'free_spans_lock taken on ${takes} of ${refills} refills (more than one in ten)'
}
