// cx-home/v#62: gc_thread_allocated is the CALLING thread's monotone count of allocated bytes.
// cx-core-code's dead-stack scrub (scrub_point, fold_scrub_after_step) asked gc_total_allocated
// whether a quarter megabyte was allocated since its last scrub: that is every thread's
// allocation, and its read walks every thread's slot. With k mutators each thread scrubbed
// 256 KB of stack k times as often as its own allocation asks, and each scrub point read k
// slots that their owners write on every allocation: template-render's CPU per unit grew from
// 132 us at k=12 to 238 us at k=28 (misc-epic-56), and a sample at k=20 read the scrub's memset
// as ~9 % of the CPU (misc-epic-57). Another thread's allocation must not move this thread's
// count; this thread's own must, across a collection too.
//
//   ../../v -gc e test bench/parallel-alloc/vgc_thread_allocated_test.v
module main

const quarter = u64(256 * 1024)

@[noinline]
fn churn(n int) int {
	mut total := 0
	for i in 0 .. n {
		s := 'x'.repeat(240 + i % 16)
		total += s.len
	}
	return total
}

fn other_thread(n int) u64 {
	b := gc_thread_allocated()
	churn(n)
	return gc_thread_allocated() - b
}

fn test_another_threads_allocation_does_not_move_this_threads_count() {
	total0 := gc_total_allocated()
	mine0 := gc_thread_allocated()
	t := spawn other_thread(32768) // ~8 MB in the other thread
	theirs := t.wait()
	mine := gc_thread_allocated() - mine0
	total := gc_total_allocated() - total0
	assert theirs >= u64(32768) * 240, 'the other thread counted ${theirs} of its ~8 MB'
	assert total >= theirs, 'the process total ${total} is under the other thread ${theirs}'
	assert mine < quarter, 'this thread counted ${mine} B of another thread allocation'
}

fn test_this_threads_own_allocation_counts_across_a_collection() {
	b := gc_thread_allocated()
	churn(8192) // ~2 MB
	gc_collect()
	mid := gc_thread_allocated()
	churn(8192)
	after := gc_thread_allocated()
	assert mid - b >= u64(8192) * 240, 'counted ${mid - b} of ~2 MB before the collection'
	assert after >= mid, 'the count went back at a collection (${mid} -> ${after})'
	assert after - b >= u64(16384) * 240, 'counted ${after - b} of ~4 MB across a collection'
}

// cx-private#1923 §1 (misc-epic-117): a large object (a span of its own, vgc_alloc_large) is this
// thread's allocation too. It was counted in the process-wide total only, so cx-core-code's fold
// scrub asked the process-wide count instead (a fold step that builds one large answer moved this
// thread's count by nothing) — and at k mutators the process-wide count brought each worker's
// 256 KB scrub due k times as often as its own work: json-codec 1 KB at k=28 spent ~10 % of its CPU
// in that memset (cx_stack_scrub -> __bzero, 4,573 of 45,280 busy samples; none at k=1).
@[noinline]
fn large_churn(n int) int {
	mut total := 0
	for _ in 0 .. n {
		a := []u8{len: 4 * 1024 * 1024} // a span of its own
		total += a.len
	}
	return total
}

fn other_large(n int) u64 {
	b := gc_thread_allocated()
	large_churn(n)
	return gc_thread_allocated() - b
}

fn test_a_large_allocation_is_this_threads_and_not_anothers() {
	b := gc_thread_allocated()
	large_churn(8) // 32 MB in eight large objects
	mine := gc_thread_allocated() - b
	assert mine >= u64(8) * 4 * 1024 * 1024, 'this thread counted ${mine} B of its 32 MB of large objects'
	m0 := gc_thread_allocated()
	t := spawn other_large(8)
	theirs := t.wait()
	moved := gc_thread_allocated() - m0
	assert theirs >= u64(8) * 4 * 1024 * 1024, 'the other thread counted ${theirs} B of its 32 MB'
	assert moved < quarter, 'this thread counted ${moved} B of another thread large objects'
}
