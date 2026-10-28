// vgc_kept_frame_passed_over_test.v — a pooled large object's span kept whole
// for its own size (vgc_pool_keeps_whole) is passed over for the next pooled
// span up that fits, before the arena tail (cx-home/v#58, vgc_pool_best_fit):
// the best fit is the smallest span that covers a request, and the third cut
// answered the tail as soon as that smallest span was a kept frame, while a
// larger pooled piece — a size asked for once, a merged run — sat idle. With
// the tails spent the same walk splits the kept frame only once nothing else
// fits: the writer at 1.5M rows read its 2637-page request split the
// 4825-page frame with 196 MB pooled, and the next period's 4825-page request
// carved a new arena (9 arenas on the third cut; the H row of
// measure/bin/collector-epic/bench58.out).
//
// The shape: a 38 MB frame dropped and collected twice (the size recurs: a
// kept frame), a 1 MB separator held so the next span does not merge with it,
// a 48 MB buffer dropped and collected (asked for once: split freely), then
// a 21 MB buffer held, then the next 38 MB request. On the third cut the
// 21 MB request went to the arena tail (the 38 MB frame was the smallest fit
// and kept), so the committed arena bytes (gc_memory_use) grew by 21 MB; now
// it splits the 48 MB span and the 38 MB request takes the frame, so they do
// not grow. Its own process (a fresh heap: one arena with its tail free).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_kept_frame_passed_over_test.v
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

fn test_a_kept_frame_is_passed_over_for_a_larger_pooled_span() {
	n := 38 * mb
	assert drop_frame(n) == n
	gc_collect()
	assert drop_frame(n) == n // the second period's frame: the size recurs
	sep := fill(mb) // held: the next span is not adjacent to the frame
	gc_collect()
	assert drop_frame(48 * mb) == 48 * mb // asked for once: split freely
	gc_collect()
	use0 := gc_memory_use()
	over_half := fill(21 * mb)
	use1 := gc_memory_use()
	again := fill(n)
	use2 := gc_memory_use()
	println('vgc_kept_frame_passed_over: committed ${use0 / mb} MB with the 38 MB frame and a 48 MB span pooled, ${use1 / mb} MB after a 21 MB buffer, ${use2 / mb} MB after the next 38 MB frame (${sep.len} ${over_half.len} ${again.len})')
	assert use0 > 0
	assert use1 <= use0 + mb, 'the 21 MB buffer did not come out of the pooled 48 MB span: committed ${use0 / mb} -> ${use1 / mb} MB'
	assert use2 <= use0 + mb, 'the next 38 MB frame did not take the kept span: committed ${use0 / mb} -> ${use2 / mb} MB'
}
