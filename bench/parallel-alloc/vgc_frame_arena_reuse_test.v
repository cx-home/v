// vgc_frame_arena_reuse_test.v — a frame's run is reused across periods of
// the same shape although smaller requests live between the periods
// (cx-home/v#58, the bar: freed spans are reused across batches of the same
// shape, so committed bytes level off near the working set). A request of a
// quarter arena or more (vgc_frame_pages, 2,048 pages) is placed in a frame
// arena, which holds such requests only, and a smaller request never takes a
// frame arena's tail or run (vgc_arena_pick, vgc_pool_at in
// vlib/builtin/vgc_d_vgc.c.v). Before, the arena of a frame handed its tail
// to the buffers after the frame, and a buffer between the periods, larger
// than any tail left, split the frame's pooled run — the next period's frame
// carved an arena while the run's remainder sat pooled, as the batch writer's
// frames did every period (measure/collector-epic-73, the carve lines).
//
// The shape (pages of 8 KB; the array's header adds one to each): a
// 5000-page frame, two 1000-page buffers after it, the frame dropped and
// collected (its run pooled), a 1500-page buffer held (more than the arena's
// tail: on 404be8c46 it splits the frame's run), then the next period's
// frame: it takes the first frame's run in place. Four more periods, each
// dropping the buffer of two periods back (the last frame dropped already:
// every frame is dropped at once, its address kept off the stack's roots),
// collecting and holding a drifting buffer (1600 to 1900 pages): every frame
// takes the run in place and the arena count holds from the first frame
// on. Its own process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frame_arena_reuse_test.v
module main

const page = 8192 // vgc's page
const mask = usize(0x5a5a5a5a5a5a5a5a) // the run's address kept off the stack's roots

@[noinline]
fn fill(n int) []u8 {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = u8(i)
	}
	return b
}

@[noinline]
fn drop_frame(n int) usize {
	b := fill(n)
	return usize(b.data) ^ mask
}

// hold fills a buffer into the list from its own frame: the test's frame
// keeps no copy of the buffer's address for the stack scan to find
@[noinline]
fn hold(mut bufs [][]u8, n int) {
	bufs << fill(n)
}

@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

fn test_a_frame_takes_its_run_in_place_past_the_buffers_between_the_periods() {
	n := 5000 * page
	key := drop_frame(n) // period 1's frame, dropped
	arenas1 := vgc_arenas_count()
	mut bufs := [][]u8{cap: 16} // never grown: a grown list's old block kept the dropped buffers' addresses
	hold(mut bufs, 1000 * page) // the period's buffers after the frame, held
	hold(mut bufs, 1000 * page)
	scrub_stack()
	gc_collect() // the frame's run is pooled
	hold(mut bufs, 1500 * page) // between the periods: more than any tail left
	key2 := drop_frame(n) // period 2's frame
	println('vgc_frame_arena_reuse: period 2 frame at ${key2 ^ mask} vs run ${key ^ mask}, arenas ${arenas1} -> ${vgc_arenas_count()}')
	assert key2 == key, 'the second period\'s frame did not take the first\'s run in place: ${key2 ^ mask} vs ${key ^ mask}'
	assert vgc_arenas_count() == arenas1, 'the arena count moved over the second period: ${arenas1} -> ${vgc_arenas_count()}'
	for p in 3 .. 7 {
		bufs[p - 3] = []u8{} // the buffer of two periods back drops
		scrub_stack()
		gc_collect() // the last period's frame and that buffer are pooled
		hold(mut bufs, (1300 + 100 * p) * page) // this period's buffer, held
		kp := drop_frame(n) // this period's frame
		assert kp == key, 'period ${p}\'s frame did not take the run in place: ${kp ^ mask} vs ${key ^ mask}'
		assert vgc_arenas_count() == arenas1, 'the arena count moved at period ${p}: ${arenas1} -> ${vgc_arenas_count()} (${bufs.len} buffers)'
	}
	println('vgc_frame_arena_reuse: six periods in place, arenas ${vgc_arenas_count()} (${bufs.len} buffers)')
}
