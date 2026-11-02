// vgc_frame_takes_the_plain_tail_test.v — a frame request with nothing of
// its kind and no plain run of its length takes a plain tail before an
// arena is carved (cx-home/v#58; vgc_span_alloc_once in
// vlib/builtin/vgc_d_vgc.c.v), and its run there keeps its size for the
// next request of it (vgc_pool_keeps_size). Before, a plain tail stayed the
// plain requests' and a recurring frame with its first run live carved a
// frame arena beside it: the 300,000-record JSON convert's 2,326-page
// document's second request (the output, the input live) and its 3,584-page
// output buffer carved a frame arena each beside plain tails of 3,840–4,991
// pages, 4 arenas against 2 (measure/collector-epic-78, the convert's carve
// lines; the gate's convert.json_300k_arenas row).
//
// The shape (pages of 8 KB; the array's header adds one to each; a frame
// request rounds to a sixteenth of the power of two below it from its first
// request: 2501 -> 2560 pages): a 2500-page frame asked for once lies plain
// in the first arena's tail, held; asked for again — the size recurs and the
// kinds begin, nothing of its kind, no plain run of its length, the plain
// tail holding it — the second lies in that tail beside the first, and the
// arena count holds (on 7551309e2 it carves a frame arena of its own).
// Dropped and collected, its run is pooled plain and whole, and the third
// request takes it in place. Its own process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frame_takes_the_plain_tail_test.v
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

fn test_a_recurring_frame_takes_the_plain_tail_before_a_carve() {
	n := 2500 * page
	held := fill(n) // asked for once: plain, the first arena's tail, held
	hi, hf := vgc_arena_probe(held.data)
	assert hi >= 0 && !hf, 'the once-asked 2500-page frame is not plain: arena ${hi} frames=${hf}'
	arenas0 := vgc_arenas_count()
	key1 :=
		drop_frame(n) // the size recurs (the kinds begin): nothing of its kind, no plain run of its length, the plain tail holds it
	a1, f1 := vgc_arena_probe(voidptr(key1 ^ mask))
	assert vgc_frames_probe(), 'the frame arenas have not begun at the second request of a frame size'
	arenas1 := vgc_arenas_count()
	println('vgc_frame_takes_the_plain_tail: the recurring 2500-page frame at ${key1 ^ mask} in arena ${a1} frames=${f1} (the held one: arena ${hi}), arenas ${arenas0} -> ${arenas1}')
	assert arenas1 == arenas0, 'the recurring frame carved an arena beside a plain tail that holds it: ${arenas0} -> ${arenas1}'
	assert a1 == hi && !f1, 'the recurring frame did not take the plain tail beside its held first: arena ${a1} frames=${f1}, not ${hi}'
	scrub_stack()
	gc_collect()
	gc_collect() // its run is pooled, plain, and keeps its size (the second collection: the sweep done)
	p1, born1, pooled1 := vgc_span_probe(voidptr(key1 ^ mask))
	assert pooled1 && born1 && p1 == 2560, 'the frame\'s run in the plain tail did not keep its size: ${p1} pages (pooled=${pooled1}), not 2560 (2501 rounded)'
	again := fill(n) // the third request: its plain run, in place
	key2 := usize(again.data) ^ mask
	assert key2 == key1, 'the third request did not take the frame\'s plain run in place: ${key2 ^ mask} vs ${key1 ^ mask}'
	assert vgc_arenas_count() == arenas0, 'the third request carved an arena: ${arenas0} -> ${vgc_arenas_count()}'
	println('vgc_frame_takes_the_plain_tail: the third request in place at ${key2 ^ mask}, arenas ${vgc_arenas_count()} (${held.len} ${again.len})')
}
