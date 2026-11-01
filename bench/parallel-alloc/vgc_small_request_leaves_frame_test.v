// vgc_small_request_leaves_frame_test.v — a small request leaves a kept
// frame whole when no tail and nothing else serves it (cx-home/v#58;
// vgc_pool_small_leaves_whole in vlib/builtin/vgc_d_vgc.c.v): the arena
// carved for the request serves the small requests after it from its tail,
// and the frame's run is there for its next period. Before, the run was
// split for the small request (vgc_get_free_span_locked's last resort) and
// the next period's frame carved an arena anyway, every period a small
// piece was live inside the run (measure/collector-epic-71's carve lines:
// 6144-page frames carved beside 5,968–5,984-page cold runs).
//
// The shape (pages of 8 KB; the array's header adds one to each; every
// request under a quarter arena, so all of it is one plain arena — a
// request of 2,048 pages or more goes to a frame arena of its own, which
// no smaller request shares, vgc_frame_pages): a 1500-page frame dropped
// and collected twice (the size recurs: a kept run), a 1 MB separator
// held, the arena's tail spent by held buffers of 15 MB and a last one
// (vgc_memory_use reads the carved bytes of the one arena), then an
// 80-page request held. On b559cd167 the request splits the run: the
// run's base address is the request's span (80 pages, in use). Now the
// run is whole and pooled (1501 pages) and the arena count is 2; the next
// 1500-page frame takes it and the count holds. Its own process (a fresh
// heap: one arena).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_small_request_leaves_frame_test.v
module main

const mb = 1024 * 1024
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

fn test_a_small_request_leaves_a_kept_frame_whole() {
	n := 1500 * page
	_ = drop_frame(n)
	scrub_stack()
	gc_collect()
	key := drop_frame(n) // the second period's frame: the size recurs; takes the first's run
	scrub_stack()
	gc_collect() // the run is pooled, kept whole for its size
	run := voidptr(key ^ mask)
	pages0, born0, pooled0 := vgc_span_probe(run)
	assert pooled0 && born0 && pages0 >= 1500, 'the frame run is not pooled whole before the test: ${pages0} ${born0} ${pooled0}'
	sep := fill(mb) // held: nothing merges with the run
	assert vgc_arenas_count() == 1, 'more than one arena before the tail is spent'
	mut spent := [][]u8{} // held: the tail left is under the 80-page request
	for {
		tail := int(usize(64 * mb) - vgc_memory_use()) // the one arena's tail
		if tail > 16 * mb {
			spent << fill(15 * mb) // under a quarter arena: a plain request
			continue
		}
		assert tail > mb, 'no tail to spend: ${tail}'
		spent << fill(tail - mb / 2)
		break
	}
	assert vgc_arenas_count() == 1, 'spending the tail carved an arena'
	small := fill(80 * page) // held: no tail, nothing but the kept run fits
	arenas1 := vgc_arenas_count()
	pages1, born1, pooled1 := vgc_span_probe(run)
	println('vgc_small_request_leaves_frame: the run reads ${pages1} pages born=${born1} pooled=${pooled1} after an 80-page request with the tail spent, arenas ${arenas1} (${sep.len} ${spent.len} ${small.len})')
	assert pooled1 && pages1 == pages0, 'the small request split the kept run: ${pages0} -> ${pages1} pages, pooled=${pooled1}'
	assert arenas1 == 2, 'the small request did not carve its own arena: ${arenas1}'
	again := fill(n) // the next period's frame takes the run
	arenas2 := vgc_arenas_count()
	assert arenas2 == arenas1, 'the next frame carved an arena: ${arenas1} -> ${arenas2} (${again.len})'
}
