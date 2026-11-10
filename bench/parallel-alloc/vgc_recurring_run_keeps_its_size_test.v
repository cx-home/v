// vgc_recurring_run_keeps_its_size_test.v — a pooled run of a recurring size
// keeps its size through the pool's merges, so the next period's request of
// that size finds it by its exact size and takes it in place, whatever the
// order the period's frames arrive in (cx-home/v#58; vgc_pool_keeps_size in
// vlib/builtin/vgc_d_vgc.c.v, read by vgc_put_free_span's merge and
// vgc_pool_defrag). Before, two frames freed beside each other merged into a
// run of a size nothing asks for, and the period's frames, arriving
// smallest first, split it in a different order every period until a size
// found no run and carved an arena (measure/collector-epic-74, the batch
// writer's carve lines at G-1's cycles 172 and 228: 2,432 pages off the
// 5,953-page run, 4,864 off the 6,724 one, 3,072 off the 7,246 one kept for
// the 6,144-page frame, then the 6,144 frame carved).
//
// The shape (pages of 8 KB; the array's header adds one to each, and a
// frame request rounds to a sixteenth of the power of two below it from its
// first request: 6400, 5120 and 2432 pages; every request a frame's,
// vgc_frame_pages, so the frames share frame arenas and no smaller span
// sits between them; the kinds begin at the first recurring frame size,
// vgc_frames_begun, so period 0 asks for the three sizes once, plain):
// period 1 holds a 6144-page frame (its own frame arena), a 4864-page one
// and a 2382-page one after it (a second frame arena: 5120 + 2432 of 8192);
// all three dropped and collected.
// Period 2 asks for the three sizes in the same order: each takes its own
// run (the sizes now recur). Dropped and collected again, period 3 asks in
// another order — 4864 first, then 6144, then 2382. On a98e5e6dc the
// 4864- and 2382-page runs have merged into one 7248-page run kept for the
// 6144-page frame, and the 4864 request, with no tail and nothing else
// fitting, splits the 6144-page run instead; the 6144 request then splits
// the 7248-page run, and the 2382 request finds the two remainders (1280
// and 1103 pages) short of it and carves a third arena. Now every frame
// takes the run its size left, in place, and the arena count holds at two
// — period 0's two plain arenas: period 1 takes period 0's runs in place
// there (a frame with nothing of its kind takes a plain pooled run before a
// carve), and a run of a recurring frame size keeps its size wherever it
// lies. Its own process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_recurring_run_keeps_its_size_test.v
module main

const page = 8192 // vgc's page
const mask = usize(0x5a5a5a5a5a5a5a5a) // the runs' addresses kept off the stack's roots

@[noinline]
fn fill(n int) []u8 {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = u8(i)
	}
	return b
}

@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

// a period: the three frames asked for in the given order, dropped at once;
// their addresses answered by size (6144, 4864, 2382 pages)
@[noinline]
fn period(order []int) (usize, usize, usize) {
	mut k6 := usize(0)
	mut k4 := usize(0)
	mut k2 := usize(0)
	// the period's frames are held until it ends, then dropped at once: a
	// collection a later frame's request brings on must not free an earlier
	// frame, whose run would then serve it. An -O0 build kept each dropped
	// frame named by a dead stack slot through those collections; an
	// optimized one does not, and the three frames shared one arena
	// (cx-home/v#66). `held` is in memory (its address goes to the pushes)
	// until period returns; scrub_stack clears it before the collections.
	mut held := [][]u8{cap: 3}
	for n in order {
		b := fill(n * page)
		k := usize(b.data) ^ mask
		held << b
		match n {
			6144 { k6 = k }
			4864 { k4 = k }
			else { k2 = k }
		}
	}
	assert held.len == order.len
	return k6, k4, k2
}

fn test_a_recurring_run_keeps_its_size_and_the_next_period_takes_it_in_place() {
	_, _, _ =
		period([6144, 4864, 2382]) // period 0: each size asked for once, plain; the frame arenas begin at the second request
	scrub_stack()
	gc_collect()
	gc_collect()
	k6, k4, k2 := period([6144, 4864, 2382])
	a6, f6 := vgc_arena_probe(voidptr(k6 ^ mask))
	a4, f4 := vgc_arena_probe(voidptr(k4 ^ mask))
	a2, f2 := vgc_arena_probe(voidptr(k2 ^ mask))
	// period 1 takes period 0's plain runs in place (a frame with nothing of
	// its kind takes a plain pooled run before a carve): the frames lie in
	// the plain arenas, and a run of a recurring frame size keeps its size
	// there too
	assert !f6 && !f4 && !f2, 'a frame is in a frame arena while its first run sat pooled plain: ${f6} ${f4} ${f2}'
	assert a4 == a2 && a6 != a4, 'the 4864- and 2382-page frames do not share an arena of their own: ${a6} ${a4} ${a2}'
	arenas1 := vgc_arenas_count()
	scrub_stack()
	gc_collect()
	gc_collect()
	k6b, k4b, k2b := period([6144, 4864, 2382]) // the second period: the sizes recur
	assert k6b == k6 && k4b == k4 && k2b == k2, 'the second period did not take the first\'s runs in place: ${k6b == k6} ${k4b == k4} ${k2b == k2}'
	scrub_stack()
	gc_collect()
	gc_collect()
	p4, born4, pooled4 := vgc_span_probe(voidptr(k4 ^ mask))
	p2, born2, pooled2 := vgc_span_probe(voidptr(k2 ^ mask))
	println('vgc_recurring_run_keeps_its_size: after the second period the 4864-page run reads ${p4} pages (born=${born4} pooled=${pooled4}), the 2382-page one ${p2} (born=${born2} pooled=${pooled2}), arenas ${vgc_arenas_count()}')
	assert pooled4 && born4 && p4 == 5120, 'the 4864-page frame\'s run did not keep its size: ${p4} pages (pooled=${pooled4}), not 5120 (4865 rounded)'
	assert pooled2 && born2 && p2 == 2432, 'the 2382-page frame\'s run did not keep its size: ${p2} pages (pooled=${pooled2}), not 2432 (2383 rounded)'
	k6c, k4c, k2c := period([4864, 6144, 2382]) // the third period, in another order
	arenas3 := vgc_arenas_count()
	println('vgc_recurring_run_keeps_its_size: the third period (4864, 6144, 2382) reads in place ${k4c == k4} ${k6c == k6} ${k2c == k2}, arenas ${arenas1} -> ${arenas3}')
	assert k4c == k4, 'the 4864-page frame did not take its own run in place'
	assert k6c == k6, 'the 6144-page frame did not take its own run in place'
	assert k2c == k2, 'the 2382-page frame did not take its own run in place'
	assert arenas3 == arenas1, 'the third period carved an arena: ${arenas1} -> ${arenas3}'
}
