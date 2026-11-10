// vgc_small_request_takes_plain_tail_test.v — a small request with nothing
// of its kind takes a PLAIN kept run's tail, not a new arena, when the run's
// remainder still holds every recurring size it is kept for (cx-home/v#58;
// vgc_get_plain_kept_tail in vlib/builtin/vgc_d_vgc.c.v, the small world's
// own kept-tail rule — vgc_pool_kept_tail — read across the kinds). Before
// (8b064e80be), a request under the rounding's floor took nothing of the
// other kinds and carved a small arena: the batch writer's 1-, 30-, 65- and
// 87-page requests carved three small arenas a run beside plain cold runs
// of 6,464–8,181 pages (measure/collector-epic-82, the G runs' carve lines
// at cycles 96, 126, 200, 208, 265, 414 and 436).
//
// The shape (pages of 8 KB; the array's header adds one to each): in the
// plain world a 1000-page buffer (from the rounding's floor up, under a
// frame: plain) beside a 300-page one, the buffer dropped and collected,
// asked for again (the size recurs: a kept run) and dropped with its
// neighbour, then one collection: the neighbour joins the run at its free
// (1300 pages, kept for 1000). Then the small arena's tail is spent by held
// buffers (spend_tail) and a 25-page request held: the small world holds no
// tail and no run. On 8b064e80be the request carves a second small arena
// and the run stays 1300 pages. Now the request lies in the plain arena at
// the run's old tail, the run reads 25 pages shorter at the same base,
// pooled, and the arena count holds; the next 1000-page buffer takes the run
// and the count holds. Its own process (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_small_request_takes_plain_tail_test.v
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

// run_and_neighbour carves the run and its neighbour while the run is live,
// then drops the run: a collection the neighbour's request brings on (the
// heap's goal is small in a fresh process) must not free the run first, or
// the neighbour takes the run's own pages. An -O0 build kept the dropped run
// named by a dead stack slot through that collection; an optimized one does
// not (cx-home/v#66).
@[noinline]
fn run_and_neighbour(n int, m int, mut nb []u8) usize {
	b := fill(n)
	nb = fill(m)
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

// spend_tail holds small buffers until the small arena's tail is under 24
// pages: every request under the rounding's floor (256 pages), so nothing
// of it touches the plain world.
fn spend_tail(arena int, mut spent [][]u8) {
	for {
		tail := int(vgc_arena_tail_probe(arena))
		if tail > 251 {
			spent << fill(250 * page) // 251 pages: under the floor
		} else if tail > 24 {
			spent << fill((tail - 9) * page) // the rest, 8 pages left
		} else {
			break
		}
	}
}

fn test_a_small_request_takes_a_plain_kept_runs_tail() {
	n := 999 * page // 1000 pages with the header: plain
	mut buf := []u8{}
	key := run_and_neighbour(n, 299 * page, mut buf) // 300 pages, carved right after the run: its neighbour
	assert usize(buf.data) == (key ^ mask) + 1000 * usize(page), 'the neighbour was not carved right after the run: ${usize(buf.data)} vs ${
		(key ^ mask) + 1000 * usize(page)}'

	scrub_stack()
	gc_collect()
	key2 := drop_run(n) // the second period: the size recurs; takes the first's run
	assert key2 == key, 'the second period did not take the first run'
	buf = []u8{} // the neighbour drops with the run: it joins the run at its free (one collection frees both hot)
	scrub_stack()
	gc_collect() // the run is pooled with its neighbour, kept for its size
	run := voidptr(key ^ mask)
	parena, pkind := vgc_arena_kind_probe(run)
	assert parena >= 0 && pkind == 0, 'the 1000-page run is not in a plain arena: arena ${parena} kind=${pkind}'
	pages1, born1, pooled1 := vgc_span_probe(run)
	assert pooled1 && born1 && pages1 >= 1290, 'the neighbour did not join the run: ${pages1} pages, born=${born1} pooled=${pooled1}'

	probe := fill(10 * page) // the small arena
	sarena, skind := vgc_arena_kind_probe(probe.data)
	assert sarena >= 0 && skind == 2 && sarena != parena, 'the 11-page buffer is not in a small arena of its own: arena ${sarena} kind=${skind} (plain ${parena})'
	mut spent := [][]u8{} // held: the small tail left is under the 25-page request
	spend_tail(sarena, mut spent)
	arenas1 := vgc_arenas_count()
	pages_s, born_s, pooled_s := vgc_span_probe(run)
	assert pooled_s && born_s && pages_s == pages1, 'spending the small tail touched the plain run: ${pages1} -> ${pages_s} pages, pooled=${pooled_s}'
	small :=
		fill(24 * page) // 25 pages, held: no small tail, no small run — the plain kept run's tail, past the 1000-page size
	arenas2 := vgc_arenas_count()
	pages2, born2, pooled2 := vgc_span_probe(run)
	si, sk := vgc_arena_kind_probe(small.data)
	println('vgc_small_request_takes_plain_tail: the run reads ${pages2} pages born=${born2} pooled=${pooled2} after a 25-page request with the small tail spent, arenas ${arenas1} -> ${arenas2}, the request in arena ${si} kind=${sk} (${probe.len} ${spent.len} ${small.len})')
	assert arenas2 == arenas1, 'the small request carved an arena instead of taking the plain kept run\'s tail: ${arenas1} -> ${arenas2}'
	assert si == parena && sk == 0, 'the small request does not lie in the plain arena: arena ${si} kind=${sk} (plain ${parena})'
	assert pooled2 && pages2 < pages1 && pages2 >= 1000, 'the kept run did not give its tail: ${pages1} -> ${pages2} pages, pooled=${pooled2}'
	off := usize(small.data) - usize(run) // the request sits in the run's old extent, past its remainder
	assert usize(small.data) > usize(run) && off >= usize(pages2) * usize(page)
		&& off < usize(pages1) * usize(page), 'the request is not the run\'s tail: offset ${off} of ${usize(pages1) * usize(page)} (remainder ${pages2} pages)'
	again := fill(n) // the next period takes the run
	arenas3 := vgc_arenas_count()
	assert arenas3 == arenas2, 'the next period carved an arena: ${arenas2} -> ${arenas3}'
	assert usize(again.data) == usize(run), 'the next period did not take the run: ${usize(again.data)} vs ${usize(run)}'
}
