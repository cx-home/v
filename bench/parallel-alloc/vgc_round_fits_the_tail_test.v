// vgc_round_fits_the_tail_test.v — the rounding of a large request (vgc_large_round,
// cx-home/v#58) never costs an arena: a rounded size that no pooled span and no
// arena tail serves falls back to the exact size before an arena is carved
// (vgc_span_alloc_floor). The 300,000-record JSON convert's doubled buffers
// (1025, 2049, 4097 pages) rounded to the sixteenth of the power of two above
// them no longer shared an arena with the 3498-page buffer beside them, and the
// fifth arena's carve ran a collection the convert on the exact sizes never
// reached (measure/collector-epic-52: 4 arenas against 2, 8 cycles against 7).
// The fallback reads the arena tails of the request's kind: a frame request's
// (a quarter arena or more, vgc_frame_pages) are the frame arenas' tails.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_round_fits_the_tail_test.v
module main

const page = 8192

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

// A 5900-page frame is asked for once and dropped (the drift signal for the
// block (5888, 6144]), a 2200-page buffer held after it spends its arena's
// tail (its block (2176, 2304] is its own: the 2060-page objects below stay
// exact); then 2060-page objects are held until one opens an arena — the
// frame's run is split down and spent, and the new arena holds 6131 pages
// of tail. A 6080-page request, a neighbour of the 5900, rounds to 6144,
// which no tail serves; its exact size fits the tail: no arena is carved,
// and the committed bytes grow by the exact request, under the rounded one.
// Every request here is a quarter arena or more (cx-home/v#58,
// vgc_frame_pages), so all of it is the frame arenas: a smaller object
// would open a plain arena, whose tail serves no frame request.
fn test_a_rounded_request_that_misses_every_tail_takes_one_at_its_exact_size() {
	assert drop_frame(5900 * page) == 5900 * page
	tail := fill(2200 * page) // held: the frame's arena has no tail left
	gc_collect()
	mut held := [][]u8{}
	mut opened := false
	for _ in 0 .. 40 {
		a0 := vgc_arena_count()
		held << fill(2060 * page)
		if vgc_arena_count() > a0 {
			opened = true
			break
		}
	}
	assert opened, 'no 2060-page object opened an arena in 40 tries'
	arenas := vgc_arena_count()
	use0 := gc_memory_use()
	big := fill(6080 * page)
	use1 := gc_memory_use()
	took := (use1 - use0) / page
	println('vgc_round_fits_the_tail: ${held.len} objects of 2060 pages opened arena ${arenas}; the 6080-page request took ${took} pages of tail, arenas ${vgc_arena_count()} (${tail.len})')
	assert vgc_arena_count() == arenas, 'the 6080-page request (rounded to 6144) carved an arena though its exact size fit the 6131-page tail'
	assert took >= 6080 && took < 6144, 'the request took ${took} pages, not its exact 6080 under the rounded 6144'
	assert big.len == 6080 * page
}
