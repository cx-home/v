// vgc_heap_usage_fields_test.v — gc_heap_usage() carries Boehm's meanings under
// vgc (cx-private#1796): bytes_since_gc is what the program allocated since the
// last completed collection, never the collection count; unmapped_bytes is what
// the pool trim returned to the OS, never the lifetime allocation total; the
// collection count is gc_cycles().
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_heap_usage_fields_test.v
module main

fn keep(n int) [][]u8 {
	mut out := [][]u8{cap: n}
	for _ in 0 .. n {
		out << []u8{len: 4096}
	}
	return out
}

fn test_bytes_since_gc_counts_bytes_and_gc_cycles_counts_collections() {
	gc_collect()
	c0 := gc_cycles()
	before := gc_heap_usage().bytes_since_gc
	held := keep(1024) // 4 MB in 4 KB arrays — under the pacer's first headroom
	after := gc_heap_usage().bytes_since_gc
	assert held.len == 1024
	if gc_cycles() == c0 {
		// no collection ran in between: the counter holds every byte since c0
		assert after >= before + usize(1024 * 4096), 'bytes_since_gc must count the 4 MB allocated since the collection: before=${before} after=${after}'
	}
	assert after != usize(gc_cycles()), 'bytes_since_gc is not the collection count'
	gc_collect()
	assert gc_cycles() >= c0 + 1, 'gc_cycles counts the explicit collection'
	since := gc_heap_usage().bytes_since_gc
	assert since < usize(1024 * 4096), 'a collection resets bytes_since_gc: ${since}'
}

fn test_unmapped_is_not_the_lifetime_allocation_total() {
	_ := keep(1024)
	u := gc_heap_usage()
	assert u.unmapped_bytes < gc_total_allocated(), 'unmapped_bytes ${u.unmapped_bytes} must not be the lifetime total ${gc_total_allocated()}'
}
