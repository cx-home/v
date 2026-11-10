// vgc_round_fits_the_tail_test.v — the rounding of a large request (vgc_large_round,
// cx-home/v#58) never costs an arena: a rounded size that no pooled span and no
// arena tail serves falls back to the exact size before an arena is carved
// (vgc_span_alloc_floor). The 300,000-record JSON convert's doubled buffers
// (1025, 2049, 4097 pages) rounded to the sixteenth of the power of two above
// them no longer shared an arena with the 3498-page buffer beside them, and the
// fifth arena's carve ran a collection the convert on the exact sizes never
// reached (measure/collector-epic-52: 4 arenas against 2, 8 cycles against 7).
// The fallback reads the arena tails of the request's kind: a recurring frame
// request's (a quarter arena or more, vgc_frame_pages; rounded from its first
// request; the kind is the size's own recurrence) are the frame arenas'
// tails.
//
// The shape (pages of 8 KB; the array's header adds one to each): the kinds
// begun by a 2047-page frame asked for twice, a 2100-page frame asked for
// once (plain, held), a once-asked buffer of the plain tail less 64 pages
// (held: the plain tail spent — a frame takes a plain tail before an arena
// is carved)
// and the 2100-page frame again (2101 pages, rounded to 2176: nothing of its
// kind, nothing of its size pooled, no plain tail — a frame arena of its own), the
// 2048-page frame asked for again from that arena's tail (3968 pages of tail
// left), then a 3900-page frame asked for once (plain, held; a plain arena
// of its own — the frame tail would not keep the frames' room past it,
// vgc_frame_tail_past_room) and again: 3901
// pages, rounded to 4096, which no frame tail holds and the pool does not
// serve; its exact size fits the tail, so no arena is carved and the
// committed bytes grow by the exact request (plus the tail's sliver after it,
// 67 pages: the carve takes a remainder too small to serve), under the
// rounded one. Its own process (a fresh heap).
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

// frames_begin asks for a 2047-page frame (2,048 pages with the header, the
// quarter) twice and drops both: the frame arenas begin at the first
// recurring frame size (cx-home/v#58, vgc_frames_begun) — the first drop is
// plain, the second takes its pooled run in place (a frame with nothing of
// its kind takes a plain pooled run before a carve).
// ask asks for n bytes and drops them: the buffer is named only in this
// frame, which scrub_stack overwrites before the collection that frees it.
@[noinline]
fn ask(n int) int {
	return fill(n).len
}

// scrub_stack overwrites the dead frames under its caller: an -O0 build left
// the dropped 2047-page frame named by a dead slot through frames_begin's
// first collection, so the first drop was not pooled there as it is at
// -O1/-O2 (cx-home/v#66); every build now drops it.
@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

// keep names a held buffer to the end of the test: an optimized build that
// reads only a buffer's length after its probe keeps no root for it, so a
// held buffer was collected under the next request and its run served that
// request (cx-home/v#66).
@[noinline]
fn keep(p voidptr) {
	if usize(p) == 1 {
		println('')
	}
}

@[noinline]
fn frames_begin() {
	for _ in 0 .. 2 {
		assert ask(2047 * page) == 2047 * page
		scrub_stack()
		gc_collect()
	}
	assert vgc_frames_probe(), 'the frame arenas have not begun after a frame size asked for twice'
}

fn test_a_rounded_request_that_misses_every_tail_takes_one_at_its_exact_size() {
	frames_begin()
	held := fill(2100 * page) // asked for once: plain, held
	hi, _ :=
		vgc_arena_probe(held.data) // the plain arena (the small one holds the runtime's own spans)
	// the plain tail spent (a frame takes a plain tail before a carve): one
	// arena so far, its carved bytes the committed ones; a once-asked buffer
	// of the tail less 64 pages, held, leaves a tail no frame fits
	assert vgc_arena_count() == 2, 'more than the small arena and the plain one before the tail is spent: ${vgc_arena_count()}'
	tail := int(vgc_arena_tail_probe(hi)) // the plain arena's tail, in pages
	mut spent := []u8{}
	if tail > 2048 + 64 {
		// tail - 64 pages with the header, asked for once: plain, held — but
		// never a size of the 3900-page frame's granule block (3841..4096):
		// a size of its block asked for before makes the once-asked 3901 a
		// drifting frame (vgc_large_round), which then takes the frame tail.
		// With frames_begin's first drop pooled (every build, cx-home/v#66)
		// the plain tail is 3968 pages and tail - 64 lay in that block.
		mut pages := tail - 64
		if pages > 3840 {
			pages = 3840
		}
		spent = fill((pages - 1) * page)
	}
	first :=
		fill(2100 * page) // 2101 pages, rounded to 2176; the size recurs, nothing of it pooled: a frame arena of its own
	fi, ff := vgc_arena_probe(first.data)
	assert fi >= 0 && ff, 'the recurring 2100-page frame is not in a frame arena: arena ${fi} frames=${ff}'
	fp, _, _ := vgc_span_probe(first.data)
	assert fp == 2176, 'the 2100-page frame\'s span is not its rounded size: ${fp} pages, not 2176'
	line := fill(2047 * page) // 2048 pages, recurring: the frame arena's tail, 3968 pages left
	li, lf := vgc_arena_probe(line.data)
	assert li == fi && lf, 'the 2048-page frame did not take the frame arena\'s tail: arena ${li} frames=${lf}'
	once :=
		fill(3900 * page) // asked for once: plain, held — a plain arena of its own: the frame tail left after it (67 pages) would not hold the largest recurring frame (vgc_frame_tail_past_room), so the mirror rule leaves the tail to the frames
	arenas0 := vgc_arena_count()
	use0 := gc_memory_use()
	second :=
		fill(3900 * page) // 3901 pages, rounded to 4096: no frame tail holds it; its exact size fits the 3968-page tail
	arenas1 := vgc_arena_count()
	use1 := gc_memory_use()
	si, sf := vgc_arena_probe(second.data)
	sp, _, _ := vgc_span_probe(second.data)
	grew := (use1 - use0) / usize(page)
	keep(held.data)
	keep(spent.data)
	keep(first.data)
	keep(line.data)
	keep(once.data)
	keep(second.data)
	println('vgc_round_fits_the_tail: the 3900-page frame (3901 pages, rounded to 4096) took a ${sp}-page span in arena ${si} (the 2100-page frame\'s: ${fi}), committed grew by ${grew} pages, arenas ${arenas0} -> ${arenas1} (${held.len} ${spent.len} ${first.len} ${line.len} ${once.len} ${second.len})')
	assert arenas1 == arenas0, 'the rounded request carved an arena while its exact size fit a tail: ${arenas0} -> ${arenas1}'
	assert si == fi && sf, 'the exact size did not take the frame arena\'s tail: arena ${si} frames=${sf}'
	assert sp >= 3901 && sp < 4096, 'the request did not fall back to its exact size: ${sp} pages, not 3901 plus the tail\'s sliver (under the rounded 4096)'
	assert grew >= 3901 && grew < 4096, 'the committed bytes did not grow by the exact request: ${grew} pages, not 3901 plus the tail\'s sliver'
}
