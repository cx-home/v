// vgc_small_request_arena_test.v — an arena carved for a small request (under
// the rounding's floor, vgc_large_round_min = 256 pages) serves small requests
// only, so the large arenas' free pages merge back whole (cx-home/v#58,
// decision 98 (a); vgc_span_alloc_once, vgc_arena_pick and the pool lookups
// by arena kind in vlib/builtin/vgc_d_vgc.c.v). Before, the small spans were
// placed between the large buffers' runs — in the plain tails after them and,
// the tails spent, split off the pooled runs as the best fit — and the batch
// writer's free pages were cut into pieces no buffer fits: at cycle 319 of
// measure/collector-epic-81's run 1 the heap held 640 MB committed for 162 MB
// live, 424 MB free in pieces (5,864 small splits off large runs, 5,402 off
// kept tails), and two defragmenting collections merged 48 KB and 8 KB of it.
// Now a request under the floor is a small request, served by small arenas
// alone (their tails and their pooled runs); a request from the floor up
// never takes a small arena's tail or run.
//
// The shape (pages of 8 KB; the array's header adds one to each): the heap's
// first arena is small (the runtime's own spans); a 1000-page buffer asked
// for once is plain and opens the plain arena; a 10-page buffer lies in the
// small arena, not beside it; the 1000-page buffer dropped and collected is
// a pooled plain run; the plain arena's tail is spent to 64 pages by a held
// buffer; a 100-page request (under the floor, over the tail left) takes the
// small arena's tail — not the pooled run's head, not an arena of its own —
// and the arena count holds; then the 1000-page buffer asked for again takes
// its run in place, at the same address, the arena count held (on ad200e62b
// the 100-page request split the 1001-page run and the second 1000-page
// request carved an arena). Its own process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_small_request_arena_test.v
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
fn drop_buffer(n int) usize {
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

fn test_a_small_request_takes_a_small_arena_and_leaves_the_plain_run_whole() {
	n := 1000 * page
	key0 := drop_buffer(n) // asked for once: plain, the plain arena
	p0, k0 := vgc_arena_kind_probe(voidptr(key0 ^ mask))
	assert p0 >= 0 && k0 == 0, 'the 1000-page buffer is not in a plain arena: arena ${p0} kind=${k0}'
	tiny := fill(10 * page) // under the floor: a small arena, not the plain one
	ti, tk := vgc_arena_kind_probe(tiny.data)
	assert tk == 2 && ti != p0, 'the 10-page buffer is not in a small arena apart from the plain one: arena ${ti} kind=${tk} (plain arena ${p0})'
	scrub_stack()
	gc_collect()
	gc_collect() // the 1000-page run is pooled, plain (the second collection: the sweep done)
	arenas0 := vgc_arenas_count()
	tail := int(vgc_arena_tail_probe(p0)) // the plain arena's tail, in pages
	assert tail > 64 + 1, 'no plain tail to spend: ${tail} pages'
	spent :=
		fill((tail - 65) * page) // tail - 64 pages with the header; asked for once: plain, held
	si, sk := vgc_arena_kind_probe(spent.data)
	assert si == p0 && sk == 0, 'the tail-spending buffer did not take the plain tail: arena ${si} kind=${sk}, not ${p0}'
	assert vgc_arenas_count() == arenas0, 'spending the plain tail carved an arena: ${arenas0} -> ${vgc_arenas_count()}'
	left := int(vgc_arena_tail_probe(p0))
	assert left < 100, 'the plain tail still holds a 100-page request: ${left} pages'
	small := fill(100 * page) // under the floor, over the plain tail left: the small arena's tail
	mi, mk := vgc_arena_kind_probe(small.data)
	println('vgc_small_request_arena: the 100-page buffer in arena ${mi} kind=${mk} (plain arena ${p0} with ${left} pages of tail; small arena ${ti}), arenas ${arenas0} -> ${vgc_arenas_count()}')
	assert mk == 2 && mi != p0, 'the 100-page request did not take a small arena: arena ${mi} kind=${mk} (plain arena ${p0})'
	assert vgc_arenas_count() == arenas0, 'the 100-page request carved an arena beside a small tail that holds it: ${arenas0} -> ${vgc_arenas_count()}'
	again := fill(n) // the plain run, whole: taken in place
	key1 := usize(again.data) ^ mask
	a1, k1 := vgc_arena_kind_probe(again.data)
	println('vgc_small_request_arena: the second 1000-page buffer at ${key1 ^ mask} vs the run ${key0 ^ mask} (arena ${a1} kind=${k1}), arenas ${vgc_arenas_count()} (${tiny.len} ${spent.len} ${small.len} ${again.len})')
	assert key1 == key0, 'the second 1000-page request did not take the first\'s run in place: ${key1 ^ mask} vs ${key0 ^ mask} (arena ${a1} kind=${k1}) — the run was split'
	assert vgc_arenas_count() == arenas0, 'the second 1000-page request carved an arena: ${arenas0} -> ${vgc_arenas_count()}'
}
