// vgc_small_request_leaves_frame_test.v — a request leaves a kept run whole
// when no tail and nothing else serves it (cx-home/v#58;
// vgc_pool_small_leaves_whole in vlib/builtin/vgc_d_vgc.c.v): the arena
// carved for the request serves the requests after it from its tail, and
// the run is there for its next period. Before, the run was split for the
// small request (vgc_get_free_span_locked's last resort) and the next
// period's request carved an arena anyway, every period a small piece was
// live inside the run (measure/collector-epic-71's carve lines: 6144-page
// frames carved beside 5,968–5,984-page cold runs).
//
// The shape, in the small world (pages of 8 KB; the array's header adds one
// to each; every request under the rounding's floor, 256 pages, so all of it
// is the small arena — decision 98 (a): a small arena serves small requests
// only, and a request from the floor up takes nothing of it, so a kept run
// and the requests an eighth of it or less meet in a small arena alone): a
// 200-page buffer dropped and collected twice (the size recurs: a kept run),
// the small arena's tail spent by held buffers (spend_tail), then a 25-page
// request held (an eighth of the run; its remainder would not hold the
// 200-page size, so the run gives no tail: vgc_pool_kept_tail). On b559cd167
// the request split the run. Now the run is whole and pooled (200 pages) and
// the arena count is one more (a small arena carved for the request); the
// next 200-page buffer takes the run and the count holds. Its own process
// (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_small_request_leaves_frame_test.v
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
fn drop_run(n int) usize {
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

// spend_tail holds buffers until the small arena's tail is under 24 pages,
// none of them able to split the kept run: a request over the run's length
// cannot, and one of 135 pages or less (the run's recurring 200-page size
// less the merge floor) is passed over for the tail (vgc_pool_keeps_whole).
fn spend_tail(arena int, run_pages int, mut spent [][]u8) {
	for {
		tail := int(vgc_arena_tail_probe(arena))
		if tail > 251 {
			spent << fill(250 * page) // 251 pages: over the run, under the floor
		} else if tail - 8 > run_pages {
			spent << fill((tail - 9) * page) // the rest of the tail, over the run
		} else if tail > 110 + 9 {
			spent << fill(100 * page) // 101 pages: passed over the kept run for the tail
		} else if tail > 24 {
			spent << fill((tail - 9) * page) // the rest, 8 pages left
		} else {
			break
		}
	}
}

fn test_a_small_request_leaves_a_kept_run_whole() {
	n := 199 * page // 200 pages with the header
	_ = drop_run(n)
	scrub_stack()
	gc_collect()
	key := drop_run(n) // the second period: the size recurs; takes the first's run
	scrub_stack()
	gc_collect() // the run is pooled, kept whole for its size
	run := voidptr(key ^ mask)
	arena, kind := vgc_arena_kind_probe(run)
	assert arena >= 0 && kind == 2, 'the 200-page run is not in a small arena: arena ${arena} kind=${kind}'
	pages0, born0, pooled0 := vgc_span_probe(run)
	assert pooled0 && born0 && pages0 >= 200, 'the run is not pooled whole before the test: ${pages0} ${born0} ${pooled0}'
	mut spent := [][]u8{} // held: the tail left is under the 25-page request
	spend_tail(arena, int(pages0), mut spent)
	arenas0 := vgc_arenas_count()
	pages_s, born_s, pooled_s := vgc_span_probe(run)
	assert pooled_s && born_s && pages_s == pages0, 'spending the tail split the kept run: ${pages0} -> ${pages_s} pages, pooled=${pooled_s}'
	small := fill(24 * page) // 25 pages, held: no tail, nothing but the kept run fits
	arenas1 := vgc_arenas_count()
	pages1, born1, pooled1 := vgc_span_probe(run)
	si, sk := vgc_arena_kind_probe(small.data)
	println('vgc_small_request_leaves_frame: the run reads ${pages1} pages born=${born1} pooled=${pooled1} after a 25-page request with the tail spent, arenas ${arenas0} -> ${arenas1}, the request in arena ${si} kind=${sk} (${spent.len} ${small.len})')
	assert pooled1 && pages1 == pages0, 'the small request split the kept run: ${pages0} -> ${pages1} pages, pooled=${pooled1}'
	assert arenas1 == arenas0 + 1 && sk == 2 && si != arena, 'the small request did not carve a small arena of its own: ${arenas0} -> ${arenas1}, arena ${si} kind=${sk}'
	again := fill(n) // the next period takes the run
	arenas2 := vgc_arenas_count()
	assert usize(again.data) == usize(run), 'the next period did not take the run: ${usize(again.data)} vs ${usize(run)}'
	assert arenas2 == arenas1, 'the next period carved an arena: ${arenas1} -> ${arenas2}'
}
