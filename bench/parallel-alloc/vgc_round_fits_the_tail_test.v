// vgc_round_fits_the_tail_test.v — the rounding of a large request (vgc_large_round,
// cx-home/v#58) never costs an arena: a rounded size that no pooled span and no
// arena tail serves falls back to the exact size before an arena is carved
// (vgc_span_alloc_floor). The 300,000-record JSON convert's doubled buffers
// (1025, 2049, 4097 pages) rounded to the sixteenth of the power of two above
// them no longer shared an arena with the 3498-page buffer beside them, and the
// fifth arena's carve ran a collection the convert on the exact sizes never
// reached (measure/collector-epic-52: 4 arenas against 2, 8 cycles against 7).
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

// A 7690-page frame is asked for once and dropped (the drift signal for the
// block (7680, 7936]); then 300-page objects are held until one opens an
// arena — every older tail is then under 300 pages and the new arena holds
// 7892 pages of tail. A 7700-page request, a neighbour of the 7690, rounds to
// 7936, which no tail serves; its exact size fits the tail: no arena is
// carved, and the committed bytes grow by the exact request, under the
// rounded one.
fn test_a_rounded_request_that_misses_every_tail_takes_one_at_its_exact_size() {
	assert drop_frame(7690 * page) == 7690 * page
	gc_collect()
	mut held := [][]u8{}
	mut opened := false
	for _ in 0 .. 400 {
		a0 := vgc_arena_count()
		held << fill(300 * page)
		if vgc_arena_count() > a0 {
			opened = true
			break
		}
	}
	assert opened, 'no 300-page object opened an arena in 400 tries'
	arenas := vgc_arena_count()
	use0 := gc_memory_use()
	big := fill(7700 * page)
	use1 := gc_memory_use()
	took := (use1 - use0) / page
	println('vgc_round_fits_the_tail: ${held.len} objects of 300 pages opened arena ${arenas}; the 7700-page request took ${took} pages of tail, arenas ${vgc_arena_count()}')
	assert vgc_arena_count() == arenas, 'the 7700-page request (rounded to 7936) carved an arena though its exact size fit the 7892-page tail'
	assert took >= 7700 && took < 7936, 'the request took ${took} pages, not its exact 7700 under the rounded 7936'
	assert big.len == 7700 * page
}
