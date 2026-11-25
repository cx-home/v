// vgc_oversized_growth_arena_test.v — a buffer past one arena's size that grows a
// little at a time reuses its arenas instead of taking a new one at every size
// (cx-private #2036, kind5e).
//
// A request larger than one arena (64 MB) takes an oversized arena of its own,
// and the free-span pool serves it again only to a request no larger than the
// freed span. Above vgc_max_pooled_pages the size was never rounded, so a
// buffer rebuilt a few pages larger each time (the store's image between 64
// and 74 MB) carved a fresh arena at every size, and the arena table filled
// long before the heap did: kind5e's store pod died with 'arenas 249/249,
// heap_live 1029 MB, soft limit 2048 MB' on a 74,100,150-byte request.
// Rounded to a sixteenth of its power of two (the pooled sizes' granule,
// vgc_large_round_up), the 24 sizes below are one size and share one arena.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_oversized_growth_arena_test.v
module main

const mb = 1024 * 1024

@[noinline]
fn buffer(n int) int {
	mut b := []u8{len: n}
	b[0] = 1
	b[n - 1] = 1
	return b.len
}

fn test_a_growing_oversized_buffer_reuses_its_arena() {
	gc_collect()
	before := vgc_arenas_count()
	mut x := 0
	for i in 0 .. 24 {
		// 65 MB, then 96 KB more each time: 24 sizes, every one larger than the last
		x += buffer(65 * mb + i * 96 * 1024)
		gc_collect()
	}
	grew := vgc_arenas_count() - before
	assert x > 0
	assert grew <= 2, '24 growing oversized buffers carved ${grew} arenas'
}
