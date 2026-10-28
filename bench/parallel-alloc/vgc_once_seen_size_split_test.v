// vgc_once_seen_size_split_test.v — a pooled large object's span whose size
// the program asked for only once is split by the smaller requests, before
// any arena tail is carved (cx-home/v#58, vgc_large_demand): the keep-whole
// rule of vgc_batch_shape_reuse_test.v is for a size that recurs.
//
// An array doubled through each size asks for every size once — cx's
// convert of a 300,000-record JSON document (its perf-pair row
// convert.json_300k_arenas) read 2 -> 4 arenas when the first cut of the
// rule kept every pooled large span whole: the one-page requests after the
// collection went to the fresh arena's tail while 24 MB sat pooled, and the
// next 8 and 32 MB requests found neither a tail nor a span.
//
// The shape: a 32 MB buffer dropped and collected (pooled whole, its size
// asked for once), then sixteen 1 MB buffers held. They come out of the
// pooled span: the committed arena bytes (gc_memory_use) do not grow. Its
// own process (a fresh heap: one arena with its tail free).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_once_seen_size_split_test.v
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

fn test_a_once_seen_size_is_split_by_the_smaller_requests() {
	n := 32 * mb
	assert drop_frame(n) == n
	gc_collect()
	use0 := gc_memory_use()
	mut held := [][]u8{}
	for _ in 0 .. 16 {
		held << fill(mb)
	}
	use1 := gc_memory_use()
	println('vgc_once_seen_size_split: committed ${use0 / mb} MB after the 32 MB frame was pooled, ${use1 / mb} MB after sixteen 1 MB buffers (${held.len})')
	assert use0 > 0
	assert use1 <= use0 + mb, 'the 1 MB buffers did not come out of the pooled 32 MB span: committed ${use0 / mb} -> ${use1 / mb} MB'
}
