// vgc_frame_arena_placement_test.v — the arena kinds (cx-home/v#58): a
// request of a quarter arena or more (vgc_frame_pages, 2,048 pages of 8 KB)
// is placed in a frame arena, a smaller one in a plain arena, and the two
// never share an arena: a frame's arena hands its tail to no buffer, so a
// frame's run merges back whole as its neighbours die (vgc_arena_pick,
// vgc_pool_at in vlib/builtin/vgc_d_vgc.c.v; vgc_arena_probe reports an
// address's arena and its kind). The quarter is the line: 2,047 pages plus
// the array's header page is a frame request, 2,046 plus one is not. Its own
// process (a fresh heap). The kinds are a size's own recurrence: a frame size
// asked for once is plain, and its second request — with its first run held,
// nothing pooled of its size — opens a frame arena (vgc_span_alloc_once); a
// 2047-page frame asked for twice first begins them (vgc_frames_begun).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frame_arena_placement_test.v
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

// frames_begin asks for a 2047-page frame (2,048 pages with the header, the
// quarter) twice and drops both: the frame arenas begin at the first
// recurring frame size (cx-home/v#58, vgc_frames_begun) — the first drop is
// plain, the second takes its pooled run in place (a frame with nothing of
// its kind takes a plain pooled run before a carve).
@[noinline]
fn frames_begin() {
	for _ in 0 .. 2 {
		assert fill(2047 * page).len == 2047 * page
		gc_collect()
	}
	assert vgc_frames_probe(), 'the frame arenas have not begun after a frame size asked for twice'
}

fn test_a_frame_and_a_buffer_never_share_an_arena() {
	frames_begin()
	first := fill(3000 * page) // asked for once: plain, held
	oi, of := vgc_arena_probe(first.data)
	assert oi >= 0 && !of, 'the 3000-page frame asked for once is in a frame arena: arena ${oi} frames=${of}'
	frame := fill(3000 * page) // the size recurs, nothing of it pooled: a frame arena
	fi, ff := vgc_arena_probe(frame.data)
	assert fi >= 0 && ff, 'the recurring 3000-page frame is not in a frame arena: arena ${fi} frames=${ff}'
	buf := fill(400 * page) // the buffer after the frame: a plain arena, not the frame's tail
	bi, bf := vgc_arena_probe(buf.data)
	assert bi >= 0 && !bf, 'the 400-page buffer is in a frame arena: arena ${bi} frames=${bf}'
	assert bi != fi, 'the buffer shares the frame\'s arena ${fi}'
	line := fill(2047 * page) // 2,048 pages with the header: a frame request
	li, lf := vgc_arena_probe(line.data)
	assert lf, 'the 2048-page request is not in a frame arena: arena ${li}'
	under := fill(2046 * page) // 2,047 pages with the header: a plain one
	ui, uf := vgc_arena_probe(under.data)
	assert !uf, 'the 2047-page request is in a frame arena: arena ${ui}'
	println('vgc_frame_arena_placement: the once-asked frame in arena ${oi}, the recurring one in ${fi}, buffer in ${bi}, the quarter line in ${li}, under it in ${ui}, arenas ${vgc_arenas_count()} (${first.len} ${frame.len} ${buf.len} ${line.len} ${under.len})')
}
