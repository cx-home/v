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
// 5000-page frame asked for once (plain), dropped and collected; asked for
// again it takes that plain run in place (the kinds are a size's own
// recurrence, and a frame with nothing of its kind takes a plain pooled run
// before a carve); two 1000-page buffers after it, the frame dropped and
// collected (its run pooled, plain), a 1500-page buffer held (more than the
// arena's tail: the plain world's last resort splits the run), then the
// next period's frame: nothing of its kind and no plain run of its length —
// the first in a frame arena. Four more periods, each dropping the buffer of
// two periods back (the last frame dropped already: every frame is dropped
// at once, its address kept off the stack's roots), collecting and holding a
// drifting buffer (1600 to 1900 pages): every frame takes the frame arena's
// run in place and the arena count holds from that frame on. Its own
// process (a fresh heap).
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
	key0 :=
		drop_frame(n) // period 0: the size asked for once is plain (the kinds are a size's own recurrence)
	scrub_stack()
	gc_collect()
	key1 :=
		drop_frame(n) // period 1's frame: nothing of its kind, its first run pooled plain — taken in place (vgc_frame_takes_the_plain_pool_test.v)
	assert key1 == key0, 'the second period\'s frame did not take the first\'s plain run in place: ${key1 ^ mask} vs ${key0 ^ mask}'
	mut bufs := [][]u8{cap: 16} // never grown: a grown list's old block kept the dropped buffers' addresses
	hold(mut bufs, 1000 * page) // the period's buffers after the frame, held
	hold(mut bufs, 1000 * page)
	scrub_stack()
	gc_collect() // the frame's run is pooled, plain
	hold(mut bufs, 1500 * page) // between the periods: more than any tail left — the plain world's last resort splits the run
	key :=
		drop_frame(n) // period 2's frame: nothing of its kind, no plain run of its length — the first in a frame arena
	ki, kf := vgc_arena_probe(voidptr(key ^ mask))
	assert ki >= 0 && kf, 'the third period\'s frame is not in a frame arena: arena ${ki} frames=${kf}'
	arenas1 := vgc_arenas_count()
	println('vgc_frame_arena_reuse: period 1 frame in place at ${key1 ^ mask}; period 2 frame in frame arena ${ki} at ${key ^ mask}, arenas ${arenas1}')
	for p in 3 .. 7 {
		bufs[p - 3] = []u8{} // the buffer of two periods back drops
		scrub_stack()
		gc_collect() // the last period's frame and that buffer are pooled
		hold(mut bufs, (1300 + 100 * p) * page) // this period's buffer, held
		kp := drop_frame(n) // this period's frame
		assert kp == key, 'period ${p}\'s frame did not take the run in place: ${kp ^ mask} vs ${key ^ mask}'
		assert vgc_arenas_count() == arenas1, 'the arena count moved at period ${p}: ${arenas1} -> ${vgc_arenas_count()} (${bufs.len} buffers)'
	}
	println('vgc_frame_arena_reuse: five periods in place in the frame arena, arenas ${vgc_arenas_count()} (${bufs.len} buffers)')
}
