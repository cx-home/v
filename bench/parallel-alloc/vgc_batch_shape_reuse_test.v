// vgc_batch_shape_reuse_test.v — a freed large object's span is reused by the
// next request of its size: the smaller requests in between do not split it
// while an arena tail serves them (cx-home/v#58: a batch writer's live heap
// held 47–222 MB while the arenas' committed bytes went 126 -> 530 MB;
// cx-platform-store#26's bulk write).
//
// The writer, read with the VGC_GCTRACE=3 carve line: every period a part
// frame grows through 10, 13, 23, 33 and 38 MB and is dropped when the next
// period's replaces it. The pool held the previous period's frames, but the
// best fit takes the smallest pooled span that covers a request, so the
// smaller requests between the periods — once the pool's smaller spans were
// spent — split the frames down (a 4285-page span read 2969 by the next
// period), and the next period's frames found no span of their sizes and
// carved new arenas: 1 -> 11 arenas over 1.5M rows (645 MB resident) with
// hundreds of MB pooled. The rule now: a request splits a pooled large
// object's span (VGC_Span.large_born) only within twice its size while an
// arena tail can serve it (vgc_pool_split_cap); past that it carves the tail,
// and only with no tail left is the span split rather than a new arena carved.
//
// The shape: a 32 MB buffer dropped and collected (pooled whole), then a 1 MB
// buffer held, then another 32 MB request. Pinned: the 1 MB request split the
// 32 MB span, and the second 32 MB request carved 32 MB of new arena. Now:
// the 1 MB request takes the arena tail and the second 32 MB request is the
// pooled span, so the committed arena bytes (gc_memory_use) grow by the 1 MB
// only. Its own process (a fresh heap: one arena with its tail free).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_batch_shape_reuse_test.v
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

fn test_a_freed_large_span_serves_the_next_request_of_its_size() {
	n := 32 * mb
	assert drop_frame(n) == n
	gc_collect()
	use0 := gc_memory_use()
	small := fill(mb)
	use1 := gc_memory_use()
	again := fill(n)
	use2 := gc_memory_use()
	println('vgc_batch_shape_reuse: committed ${use0 / mb} MB after the 32 MB frame was pooled, ${use1 / mb} MB after a 1 MB buffer, ${use2 / mb} MB after the next 32 MB frame (${small.len} ${again.len})')
	assert use0 > 0
	assert use2 <= use0 + 2 * mb, 'the next 32 MB frame did not take the pooled span: committed ${use0 / mb} -> ${use2 / mb} MB (the 1 MB buffer in between: ${use1 / mb} MB)'
}
