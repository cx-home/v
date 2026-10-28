// vgc_writer_shape_reuse_test.v — a pooled large object's span whose size
// recurs is kept whole from a request over half its size too, while an arena
// tail serves the request (cx-home/v#58, vgc_pool_keeps_whole): the split cap
// of vgc_batch_shape_reuse_test.v (twice the request) is for the pooled
// pieces whose size does not recur — a merged run, a split's remainder.
//
// The batch writer at 1.5M rows (cx-platform-store#26's bulk write, read
// with the VGC_GCTRACE=3 split line): every period its part frame grows
// through 1114, 1648, 1856, 2637, 2969, 4285 and 4825 pages, and the
// 2637-page request of one period found no span between its size and the
// 4825-page frame's, took the frame's span (2637 is over half of 4825, so
// the cap allowed it) while an arena tail served it, and the next period's
// 4825-page request carved a new arena: 8 -> 10 arenas over the run on the
// second cut (measure/bin/collector-epic/bench58.out, the G row).
//
// The shape: a 38 MB frame dropped and collected twice (the size recurs),
// then a 21 MB buffer held, then the next 38 MB request. On the second cut
// the 21 MB request split the 38 MB span and the next 38 MB request carved
// 38 MB of new arena; now the 21 MB request takes the arena tail and the
// next 38 MB request is the pooled span, so the committed arena bytes
// (gc_memory_use) grow by the 21 MB only. Its own process (a fresh heap:
// one arena with its tail free).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_writer_shape_reuse_test.v
module main

const mb = 1024 * 1024

@[noinline]
fn fill(n int) []u8 {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = u8(i)
	}
	return b
}

@[noinline]
fn drop_frame(n int) int {
	return fill(n).len
}

fn test_a_recurring_size_span_is_kept_from_a_request_over_half_its_size() {
	n := 38 * mb
	assert drop_frame(n) == n
	gc_collect()
	assert drop_frame(n) == n // the second period's frame: the size recurs
	gc_collect()
	use0 := gc_memory_use()
	over_half := fill(21 * mb)
	use1 := gc_memory_use()
	again := fill(n)
	use2 := gc_memory_use()
	println('vgc_writer_shape_reuse: committed ${use0 / mb} MB after the 38 MB frame was pooled twice, ${use1 / mb} MB after a 21 MB buffer, ${use2 / mb} MB after the next 38 MB frame (${over_half.len} ${again.len})')
	assert use0 > 0
	assert use2 <= use0 + 22 * mb, 'the next 38 MB frame did not take the pooled span: committed ${use0 / mb} -> ${use2 / mb} MB (the 21 MB buffer in between: ${use1 / mb} MB)'
}
