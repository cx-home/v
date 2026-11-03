// vgc_small_request_takes_kept_tail_test.v — a request takes a kept run's
// tail, not a new arena, when the run's remainder still holds every
// recurring size it is kept for (cx-home/v#58; vgc_pool_kept_tail and
// vgc_span_split_tail in vlib/builtin/vgc_d_vgc.c.v). Before, a request of
// an eighth of a kept run or less left the run whole and carved an arena
// (vgc_pool_small_leaves_whole, a6b748f75), and with no tail and no hot run
// left a writer run's 1- and 20-page requests carved five of its twelve
// arenas beside 5,956–8,192-page cold runs (measure/collector-epic-72, run
// G-3's carve lines).
//
// The shape, in the small world (pages of 8 KB; the array's header adds one
// to each; every request under the rounding's floor, 256 pages, so all of it
// is the small arena — decision 98 (a): a small arena serves small requests
// only, and a request from the floor up takes nothing of it, so a kept run
// and the requests an eighth of it or less meet in a small arena alone): a
// 200-page buffer beside a 40-page one, the buffer dropped and collected,
// asked for again (the size recurs: a kept run) and dropped with its
// neighbour, then one collection: the neighbour joins the run at its free
// (241 pages, kept for 200). The two drop together because an explicit
// gc_collect() trims the whole pool at its end (vgc_pool_trim_all): a run
// pooled by one collection is cold at the next, and a cold run takes no hot
// neighbour under vgc_pool_cold_merge_min pages (vgc_pool_states_meet). Then
// the small arena's tail is spent by held buffers (spend_tail) and a 25-page
// request held. On a6b748f75 the request carves a second arena and the run
// stays 241 pages. Now the run reads 25 pages shorter at the same base,
// pooled, and the arena count holds; the next 200-page buffer takes the run
// and the count holds. Its own process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_small_request_takes_kept_tail_test.v
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

fn test_a_small_request_takes_a_kept_runs_tail() {
	n := 199 * page // 200 pages with the header
	key := drop_run(n)
	mut buf := fill(40 * page) // carved right after the run: its neighbour
	assert usize(buf.data) == (key ^ mask) + 200 * usize(page), 'the neighbour was not carved right after the run: ${usize(buf.data)} vs ${
		(key ^ mask) + 200 * usize(page)}'

	scrub_stack()
	gc_collect()
	key2 := drop_run(n) // the second period: the size recurs; takes the first's run
	assert key2 == key, 'the second period did not take the first run'
	buf = []u8{} // the neighbour drops with the run: it joins the run at its free (one collection frees both hot)
	scrub_stack()
	gc_collect() // the run is pooled with its neighbour, kept for its size
	run := voidptr(key ^ mask)
	arena, kind := vgc_arena_kind_probe(run)
	assert arena >= 0 && kind == 2, 'the 200-page run is not in a small arena: arena ${arena} kind=${kind}'
	pages1, born1, pooled1 := vgc_span_probe(run)
	assert pooled1 && born1 && pages1 >= 240, 'the neighbour did not join the run: ${pages1} pages, born=${born1} pooled=${pooled1}'
	mut spent := [][]u8{} // held: the tail left is under the 25-page request
	spend_tail(arena, int(pages1), mut spent)
	arenas1 := vgc_arenas_count()
	pages_s, born_s, pooled_s := vgc_span_probe(run)
	assert pooled_s && born_s && pages_s == pages1, 'spending the tail split the kept run: ${pages1} -> ${pages_s} pages, pooled=${pooled_s}'
	small :=
		fill(24 * page) // 25 pages, held: no tail, nothing but the kept run fits — its tail, past the 200-page size
	arenas2 := vgc_arenas_count()
	pages2, born2, pooled2 := vgc_span_probe(run)
	println('vgc_small_request_takes_kept_tail: the run reads ${pages2} pages born=${born2} pooled=${pooled2} after a 25-page request with the tail spent, arenas ${arenas1} -> ${arenas2} (${buf.len} ${spent.len} ${small.len})')
	assert arenas2 == arenas1, 'the small request carved an arena instead of taking the kept run\'s tail: ${arenas1} -> ${arenas2}'
	assert pooled2 && pages2 < pages1 && pages2 >= 200, 'the kept run did not give its tail: ${pages1} -> ${pages2} pages, pooled=${pooled2}'
	off := usize(small.data) - usize(run) // the request sits in the run's old extent, past its remainder
	assert usize(small.data) > usize(run) && off >= usize(pages2) * usize(page)
		&& off < usize(pages1) * usize(page), 'the request is not the run\'s tail: offset ${off} of ${usize(pages1) * usize(page)} (remainder ${pages2} pages)'
	again := fill(n) // the next period takes the run
	arenas3 := vgc_arenas_count()
	assert arenas3 == arenas2, 'the next period carved an arena: ${arenas2} -> ${arenas3}'
	assert usize(again.data) == usize(run), 'the next period did not take the run: ${usize(again.data)} vs ${usize(run)}'
}
