// vgc_small_request_takes_kept_tail_test.v — a small request takes a kept
// run's tail, not a new arena, when the run's remainder still holds every
// recurring size it is kept for (cx-home/v#58; vgc_pool_kept_tail and
// vgc_span_split_tail in vlib/builtin/vgc_d_vgc.c.v). Before, a request of
// an eighth of a kept run or less left the run whole and carved an arena
// (vgc_pool_small_leaves_whole, a6b748f75), and with no tail and no hot run
// left a writer run's 1- and 20-page requests carved five of its twelve
// arenas beside 5,956–8,192-page cold runs (measure/collector-epic-72, run
// G-3's carve lines).
//
// The shape (pages of 8 KB; the array's header adds one to each; every
// request under the rounding's floor of 256 pages, where a run of a
// recurring size still merges with its freed neighbours — from the floor
// up a recurring run keeps its size and joins nothing, vgc_pool_keeps_size,
// so a kept run with room past its size is a merged one; and under a
// quarter arena, so all of it is one plain arena): a 200-page frame beside
// a 250-page buffer (a cold run joins a freed neighbour of 128 pages or
// more, vgc_pool_cold_merge_min), the frame dropped and collected twice
// (the size recurs: a kept run), then the buffer dropped and collected (it
// joins the run: 452 pages, kept for 201), a 1 MB separator held, the
// arena's tail spent by held buffers of 15 MB and a last one
// (vgc_memory_use reads the carved bytes of the one arena), then a 50-page
// request held. On a6b748f75 the request carves a second arena and the run
// stays whole (a 20-page one a stray pooled run serves). Now the run reads
// 51 pages shorter at the same base, pooled,
// and the arena count holds at 1; the next 200-page frame takes the run and
// the count holds. Its own process (a fresh heap: one arena).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_small_request_takes_kept_tail_test.v
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

fn test_a_small_request_takes_a_kept_runs_tail() {
	n := 200 * page
	key := drop_frame(n)
	mut buf := fill(250 * page) // carved right after the frame: its neighbour
	scrub_stack()
	gc_collect()
	key2 := drop_frame(n) // the second period's frame: the size recurs; takes the first's run
	assert key2 == key, 'the second frame did not take the first run'
	scrub_stack()
	gc_collect() // the run is pooled, kept whole for its size
	run := voidptr(key ^ mask)
	pages0, born0, pooled0 := vgc_span_probe(run)
	assert pooled0 && born0 && pages0 >= 200, 'the frame run is not pooled whole before the buffer drops: ${pages0} ${born0} ${pooled0}'
	buf = []u8{} // the buffer drops: it joins the run at its free
	scrub_stack()
	gc_collect()
	pages1, born1, pooled1 := vgc_span_probe(run)
	assert pooled1 && born1 && pages1 >= pages0 + 250, 'the buffer did not join the run: ${pages0} -> ${pages1} ${born1} ${pooled1}'
	sep := fill(mb) // held: nothing merges with the run
	assert vgc_arenas_count() == 1, 'more than one arena before the tail is spent'
	mut spent := [][]u8{} // held: the tail left is under the 50-page request
	for {
		tail := int(usize(64 * mb) - vgc_memory_use()) // the one arena's tail
		if tail > 16 * mb {
			spent << fill(15 * mb) // under a quarter arena: a plain request
			continue
		}
		assert tail > mb, 'no tail to spend: ${tail}'
		spent << fill(tail - mb / 8) // 16 pages of tail left: under the request
		break
	}
	assert vgc_arenas_count() == 1, 'spending the tail carved an arena'
	small := fill(50 * page) // held: no tail, nothing but the kept run fits
	arenas2 := vgc_arenas_count()
	pages2, born2, pooled2 := vgc_span_probe(run)
	println('vgc_small_request_takes_kept_tail: the run reads ${pages2} pages born=${born2} pooled=${pooled2} after a 50-page request with the tail spent, arenas ${arenas2} (${buf.len} ${sep.len} ${spent.len} ${small.len})')
	assert arenas2 == 1, 'the small request carved an arena instead of taking the kept run\'s tail: ${arenas2}'
	assert pooled2 && pages2 < pages1 && pages2 >= 201, 'the kept run did not give its tail: ${pages1} -> ${pages2} pages, pooled=${pooled2}'
	off := usize(small.data) - usize(run) // the request sits in the run's old extent, past its remainder
	assert usize(small.data) > usize(run) && off >= usize(pages2) * usize(page)
		&& off < usize(pages1) * usize(page), 'the request is not the run\'s tail: offset ${off} of ${usize(pages1) * usize(page)} (remainder ${pages2} pages)'
	again := fill(n) // the next period's frame takes the run
	arenas3 := vgc_arenas_count()
	assert arenas3 == 1, 'the next frame carved an arena: ${arenas2} -> ${arenas3} (${again.len})'
	assert usize(again.data) == usize(run), 'the next frame did not take the run: ${usize(again.data)} vs ${usize(run)}'
}
