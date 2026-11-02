// vgc_frame_takes_the_plain_pool_test.v — a frame with nothing of its kind
// takes a plain pooled run before an arena is carved, and a frame size asked
// for once is plain whenever it is asked for (cx-home/v#58; vgc_span_alloc_once
// in vlib/builtin/vgc_d_vgc.c.v). A frame's first period is plain — the kinds
// begin at a size's second request — and served by its kind alone the second
// request carved a frame arena while the first period's run sat pooled plain;
// the writer's 4,864-, 6,144- and 5,120-page frames carved again beside plain
// cold runs of 6,168–6,293 pages (measure/collector-epic-77, G-1's carve lines
// at cycles 117, 154, 321 and 399). And with the kinds a global switch, a
// frame asked for once after any frame size recurred was a frame request:
// the 300,000-record JSON convert's 3,498-page output buffer carved a frame
// arena beside a plain tail of 3,840 pages (the convert's carve lines; the
// gate's convert.json_300k_arenas row).
//
// The shape (pages of 8 KB; the array's header adds one to each): a
// 3000-page frame asked for once, dropped and collected (its run pooled,
// plain); asked for again it takes that run in place, in the plain arena,
// and the arena count holds; then a 2500-page frame asked for once lies in
// the plain arena's tail beside it. Its own process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frame_takes_the_plain_pool_test.v
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

@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

fn test_a_recurring_frame_takes_its_first_period_run_in_place_and_a_once_asked_frame_is_plain() {
	n := 3000 * page
	key0 := drop_frame(n) // period 0: asked for once, plain
	a0, f0 := vgc_arena_probe(voidptr(key0 ^ mask))
	assert a0 >= 0 && !f0, 'the first period\'s frame is not plain: arena ${a0} frames=${f0}'
	scrub_stack()
	gc_collect() // its run is pooled, plain
	arenas0 := vgc_arenas_count()
	again :=
		fill(n) // period 1: the size recurs (the kinds begin) — nothing of its kind, the plain pool holds its run
	key1 := usize(again.data) ^ mask
	a1, f1 := vgc_arena_probe(again.data)
	arenas1 := vgc_arenas_count()
	println('vgc_frame_takes_the_plain_pool: period 1 frame at ${key1 ^ mask} vs run ${key0 ^ mask} (arena ${a1} frames=${f1}), arenas ${arenas0} -> ${arenas1}')
	assert vgc_frames_probe(), 'the frame arenas have not begun at the second request of a frame size'
	assert key1 == key0, 'the second period\'s frame did not take the first\'s plain run in place: ${key1 ^ mask} vs ${key0 ^ mask} (arena ${a1} frames=${f1})'
	assert arenas1 == arenas0, 'the second period\'s frame carved an arena beside its pooled run: ${arenas0} -> ${arenas1}'
	once :=
		fill(2500 * page) // a frame size asked for once after the kinds began: plain, the plain arena's tail
	oi, of := vgc_arena_probe(once.data)
	assert oi == a1 && !of, 'a frame asked for once after the kinds began is not in the plain arena ${a1}: arena ${oi} frames=${of}'
	assert vgc_arenas_count() == arenas0, 'a frame asked for once carved an arena beside a plain tail: ${arenas0} -> ${vgc_arenas_count()}'
	println('vgc_frame_takes_the_plain_pool: the once-asked 2500-page frame in plain arena ${oi}, arenas ${vgc_arenas_count()} (${again.len} ${once.len})')
}
