// vgc_plain_takes_the_frame_tail_test.v — a plain request from the rounding's
// floor up (vgc_large_round_min, 256 pages) with no plain run of its length
// and no plain tail takes a FRAME arena's tail before an arena is carved
// (cx-home/v#58; vgc_span_alloc_once in vlib/builtin/vgc_d_vgc.c.v): the
// mirror of the frames' rule, a frame with nothing of its kind takes a plain
// tail (vgc_frame_takes_the_plain_tail_test.v). Before, a plain request was
// served by the plain arenas alone, and the 300,000-record JSON convert's
// 3,584-page output buffer (asked for once: plain) carved a fourth arena
// beside a frame arena's 12,032-page tail, 4 arenas against 2 on the gate's
// convert.json_300k_arenas row; the batch writer's 1,920-page buffer carved
// its eighth the same way (measure/collector-epic-79, the convert's and
// G-1's carve lines). A request under the floor still carves a plain arena:
// its kind is many and small, and a frame arena's tail is the frames'
// growth.
//
// The shape (pages of 8 KB; the array's header adds one to each): a
// 3000-page frame asked for once lies plain in the first arena, held; the
// first arena's plain tail is spent to 64 pages by a held buffer; the frame
// asked for again — the size recurs, the kinds begin, nothing of its kind,
// no plain run, no plain tail — opens a frame arena; then a 400-page buffer
// asked for once (plain, from the floor up) lies in that frame arena's tail
// and the arena count holds (on 57a28b0e6 it carves a plain arena); a
// 200-page one (under the floor) carves a plain arena of its own. Its own
// process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_plain_takes_the_frame_tail_test.v
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

fn test_a_plain_request_takes_the_frame_tail_before_a_carve() {
	n := 3000 * page
	first := fill(n) // asked for once: plain, the first arena, held
	i0, f0 := vgc_arena_probe(first.data)
	assert i0 >= 0 && !f0, 'the once-asked 3000-page frame is not plain: arena ${i0} frames=${f0}'
	assert vgc_arenas_count() == 1, 'more than one arena before the tail is spent: ${vgc_arenas_count()}'
	tail := 8192 - int(gc_memory_use() / usize(page)) // the first arena's tail, by the committed bytes
	assert tail > 64 + 1, 'no plain tail to spend: ${tail} pages'
	spent :=
		fill((tail - 65) * page) // tail - 64 pages with the header; asked for once: plain, held
	si, sf := vgc_arena_probe(spent.data)
	assert si == i0 && !sf, 'the tail-spending buffer did not take the plain tail: arena ${si} frames=${sf}, not ${i0}'
	assert vgc_arenas_count() == 1, 'spending the tail carved an arena: ${vgc_arenas_count()}'
	frame :=
		fill(n) // the size recurs (the kinds begin): nothing of its kind, no plain run, no plain tail — a frame arena
	fi, ff := vgc_arena_probe(frame.data)
	assert fi >= 0 && ff, 'the recurring 3000-page frame is not in a frame arena: arena ${fi} frames=${ff}'
	arenas1 := vgc_arenas_count()
	buf :=
		fill(400 * page) // asked for once: plain, from the floor up; no plain run of its length, no plain tail
	bi, bf := vgc_arena_probe(buf.data)
	println('vgc_plain_takes_the_frame_tail: the 400-page buffer in arena ${bi} frames=${bf} (the frame: arena ${fi}), arenas ${arenas1} -> ${vgc_arenas_count()}')
	assert vgc_arenas_count() == arenas1, 'the plain request carved an arena beside a frame tail that holds it: ${arenas1} -> ${vgc_arenas_count()}'
	assert bi == fi && bf, 'the plain request did not take the frame tail: arena ${bi} frames=${bf}, not ${fi}'
	small := fill(200 * page) // under the floor: a plain arena of its own, not the frame's tail
	ui, uf := vgc_arena_probe(small.data)
	assert !uf && ui != fi, 'the 200-page request lies in the frame arena: arena ${ui} frames=${uf}'
	assert vgc_arenas_count() == arenas1 + 1, 'the under-floor request did not carve its plain arena: ${arenas1} -> ${vgc_arenas_count()}'
	println('vgc_plain_takes_the_frame_tail: the 200-page buffer in arena ${ui} frames=${uf}, arenas ${vgc_arenas_count()} (${first.len} ${spent.len} ${frame.len} ${buf.len} ${small.len})')
}
