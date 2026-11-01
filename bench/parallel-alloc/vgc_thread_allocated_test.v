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
