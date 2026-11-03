// vgc_frames_begin_at_recurrence_test.v — the frame arenas begin at the first
// recurring frame size (cx-home/v#58; vgc_frames_begun, set by
// vgc_large_demand_note; the kind of a request is its size's own recurrence,
// vgc_span_alloc_once): a frame asked for once is placed plain, in the arena
// the buffers after it share — before and after the kinds began — and the
// kinds begin once a size of a quarter arena or more (vgc_frame_pages) is
// asked for again. With the kinds from the first frame on, the 300,000-record
// JSON convert's 2,326-page document — asked for once — carved its own frame
// arena and the buffers after it a plain one: 4 arenas against the 2 of the
// collector without the kinds (measure/collector-epic-74 and -76; the gate's
// convert.json_300k_arenas row reads 2). A frame arena exists for the frames
// that come back.
//
// The shape (pages of 8 KB; the array's header adds one to each): a
// 3000-page frame and a 400-page buffer after it, in one plain arena, then a
// once-asked buffer held that cuts the plain tail to 2700 pages — short of
// the frame (a frame takes a plain tail before an arena is carved) and still
// holding the 2500-page frame asked for once at the end; then the 3000-page
// frame asked for again: a frame arena of its own.
// Its own process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frames_begin_at_recurrence_test.v
module main

const page = 8192 // vgc's page

@[noinline]
fn fill(n int) []u8 {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = u8(i)
	}
	return b
}

fn test_a_frame_asked_for_once_is_plain_and_the_kinds_begin_at_its_second_request() {
	assert !vgc_frames_probe(), 'the frame arenas have begun before any frame'
	first := fill(3000 * page) // asked for once: plain
	fi, ff := vgc_arena_probe(first.data)
	assert fi >= 0 && !ff, 'a frame asked for once is in a frame arena: arena ${fi} frames=${ff}'
	buf := fill(400 * page) // the buffer after it shares its arena, as before the kinds
	bi, bf := vgc_arena_probe(buf.data)
	assert bi == fi && !bf, 'the buffer after a once-asked frame did not share its arena: ${bi} vs ${fi} frames=${bf}'
	assert !vgc_frames_probe(), 'the frame arenas have begun on a frame asked for once'
	// the plain tail cut to 2700 pages, held: short of the 3000-page frame (a
	// frame takes a plain tail before a carve) and still holding the 2500-page
	// one below; one arena so far, its carved bytes the committed ones
	assert vgc_arenas_count() == 2, 'more than the small arena and the plain one before the tail is cut: ${vgc_arenas_count()}'
	tail := int(vgc_arena_tail_probe(fi)) // the plain arena's tail, in pages
	assert tail > 2700 + 64, 'the first arena\'s tail is already short: ${tail} pages'
	spent :=
		fill((tail - 2701) * page) // tail - 2700 pages with the header; asked for once: plain, held
	si, sf := vgc_arena_probe(spent.data)
	assert si == fi && !sf, 'the ${tail - 2700}-page buffer did not take the plain tail: arena ${si} frames=${sf}, not ${fi}'
	again := fill(3000 * page) // the size recurs: the frame arenas begin — no plain tail holds it
	ai, af := vgc_arena_probe(again.data)
	assert vgc_frames_probe(), 'the frame arenas have not begun at the second request of a frame size'
	assert ai >= 0 && af && ai != fi, 'the recurring frame is not in a frame arena of its own: arena ${ai} frames=${af} (the plain one: ${fi})'
	once :=
		fill(2500 * page) // a frame size asked for once after the kinds began: plain, the plain arena's tail (the kind is the size's own recurrence)
	oi, of := vgc_arena_probe(once.data)
	assert oi == fi && !of, 'a frame asked for once after the kinds began is not in the plain arena ${fi}: arena ${oi} frames=${of}'
	println('vgc_frames_begin_at_recurrence: the once-asked frame in plain arena ${fi} with its buffer and the once-asked 2500-page frame, the recurring one in frame arena ${ai}, arenas ${vgc_arenas_count()} (${first.len} ${buf.len} ${spent.len} ${again.len} ${once.len})')
}
