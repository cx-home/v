// vgc_frame_block_kept_whole_test.v — a pooled large object's span is kept
// whole (vgc_pool_keeps_whole) from a request that would break it when a size
// of ITS GRANULE BLOCK recurs, not only its exact size (cx-home/v#58): a batch
// writer's part frame drifts by a few pages a period (4814, 4841, 4864, 4872
// pages at 1.5M rows), so no exact size is asked for twice while the block
// (4608, 4864] is asked for every period, and the smaller requests between
// the periods (2407–3652 pages) split the last period's span; the next frame
// then carves an arena with 100–190 MB pooled (measure/collector-epic-60, the
// G row's carve lines). The block's recurrence is counted at
// vgc_large_demand_note (vgc_large_block_demand over vgc_large_round_up's
// block) and read by vgc_large_recurs_between beside the exact sizes.
//
// The shape: a 4700-page frame held (the first period's size: its block is
// seen), a 4760-page frame dropped — rounded to 4864 pages (the drift shows)
// and carved from the tail — a 1 MB separator held so nothing merges with it,
// then a collection: the pooled run is 4864 pages and its block was asked
// for twice. Then a 2957-page request (over half the run: the split cap does
// not keep it) and the next frame, 4800 pages (rounded to 4864). On 3eeb3fff9
// the 2957-page request splits the 4864-page run (4700 and 4864 each recur
// once) and the next frame carves 4864 pages from the tail: the committed
// arena bytes (gc_memory_use) grow by the frame. Now the run is kept whole,
// the 2957-page request takes the tail and the next frame takes the run:
// the committed bytes do not grow at the frame. Its own process (a fresh
// heap: one arena with its tail free).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frame_block_kept_whole_test.v
module main

const mb = 1024 * 1024
const page = 4096

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

fn test_a_frame_of_a_recurring_block_is_kept_whole() {
	first := fill(4700 * page) // held: the first period's frame, its block (4608, 4864] seen
	assert vgc_large_round_probe(4760) == 4864
	assert drop_frame(4760 * page) == 4760 * page // the second period's frame: rounded, carved from the tail
	sep := fill(mb) // held: nothing merges with the frame's run
	gc_collect() // the 4864-page run is pooled
	assert vgc_large_recurs_probe(4000, 4864), 'the block (4608, 4864] was asked for twice (4700, then 4760 rounded to 4864) and does not recur'
	assert !vgc_large_recurs_probe(4000, 4600), 'no size under the block recurs'
	use0 := gc_memory_use()
	over_half := fill(2957 * page) // over half the run: the split cap alone does not keep it
	use1 := gc_memory_use()
	again := fill(4800 * page) // the next period's frame: rounded to 4864
	use2 := gc_memory_use()
	println('vgc_frame_block_kept_whole: committed ${use0 / mb} MB with the 4864-page run pooled, ${use1 / mb} MB after a 2957-page buffer, ${use2 / mb} MB after the next frame (${first.len} ${sep.len} ${over_half.len} ${again.len})')
	assert use0 > 0
	assert use2 <= use1 + mb, 'the next frame did not take the kept run: committed ${use1 / mb} -> ${use2 / mb} MB'
}
