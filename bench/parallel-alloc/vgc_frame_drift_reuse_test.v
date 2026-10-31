// vgc_frame_drift_reuse_test.v — a large object's request is rounded up to a
// sixteenth of the power of two at or below it (vgc_large_round, from 256
// pages: under a sixteenth of the object) once another size of its granule
// block was asked for before — the drift signal; a size asked for alone or
// again stays exact — so a frame that grows by a few pages a period asks for
// one size from its second period on and takes the last period's pooled span; and a pooled run that still holds a
// recurring size — a frame merged with its free neighbour — is kept whole
// from a smaller request as the frame's own span is (vgc_pool_keeps_whole
// through vgc_large_recurs_between). cx-home/v#58's expectation: "freed
// spans are reused across batches of the same shape, so committed bytes
// level off near the working set". The batch writer's 47 MB part frame read
// 5953 -> 6007 -> 6027 -> 6071 pages over 1.5M rows and each size carved an
// arena while 100-190 MB sat pooled — seven of the run's sixteen arenas
// (measure/collector-epic-48, B run 2); its 38 MB frames split the pooled
// 47 MB runs that a free neighbour had widened past the recurring size.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frame_drift_reuse_test.v
module main

const mb = 1024 * 1024

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

// a first size is carved exact (30 MB: 3841 pages, not the 3968 the rounding
// would give), and a neighbour of it in the same granule block (30.1 MB: 3854
// pages) is the drift signal that rounds the request to 3968 — the committed
// bytes (gc_memory_use, the arena bytes carved) grow by those page counts (a
// small span of the test's own may be carved beside them, never the rounding's
// 127 pages): the process is fresh, so neither is served from the pool.
fn test_a_first_size_is_carved_exact_and_its_neighbour_rounds() {
	page := 8192
	n1 := 3841 * page
	use0 := gc_memory_use()
	a := fill(n1)
	use1 := gc_memory_use()
	n2 := 3854 * page
	b := fill(n2)
	use2 := gc_memory_use()
	println('vgc_frame_drift_reuse: the 3841-page request took ${(use1 - use0) / usize(page)} pages, its 3854-page neighbour ${(use2 - use1) / usize(page)}')
	took1 := (use1 - use0) / usize(page)
	took2 := (use2 - use1) / usize(page)
	assert took1 >= 3841 && took1 < 3841 + 64, 'the first size of a block is carved exact: ${took1} pages, not 3841 (a small span of the test\'s own may land beside it, never the 127 pages of the rounding)'
	assert took2 >= 3968 && took2 < 3968 + 64, 'a neighbour in the block rounds to the block\'s top: ${took2} pages, not 3968'
	assert a.len == n1 && b.len == n2
}

// four periods of a frame that drifts: 47.0, 47.2, 47.4 and 47.6 MB (6017,
// 6042, 6067 and 6093 pages) are one granule block, so the first period is
// carved exact, the second — the drift shown — rounds to 6144 and carves, and
// the third and fourth find the second's span: the committed arena bytes
// (gc_memory_use) hold from the second period on. Before the rounding each
// size missed the pooled span and carved 64 MB of arena.
fn test_a_frame_that_drifts_a_few_pages_takes_the_last_periods_span() {
	n0 := 47 * mb
	assert drop_frame(n0) == n0
	gc_collect()
	use0 := gc_memory_use()
	n1 := n0 + 200 * 1024
	assert drop_frame(n1) == n1
	gc_collect()
	use1 := gc_memory_use()
	n2 := n0 + 400 * 1024
	assert drop_frame(n2) == n2
	gc_collect()
	use2 := gc_memory_use()
	n3 := n0 + 600 * 1024
	held := fill(n3)
	use3 := gc_memory_use()
	println('vgc_frame_drift_reuse: committed ${use0 / mb} MB after the 47.0 MB frame, ${use1 / mb} MB after the 47.2 MB frame (the rounded carve), ${use2 / mb} MB after the 47.4 MB frame, ${use3 / mb} MB with the 47.6 MB frame held (${held.len})')
	assert use0 > 0
	assert use1 <= use0 + 48 * mb + mb, 'the 47.2 MB frame carved more than its rounded size: committed ${use0 / mb} -> ${use1 / mb} MB'
	assert use2 <= use1 + mb, 'the 47.4 MB frame did not take the 47.2 MB frame\'s span: committed ${use1 / mb} -> ${use2 / mb} MB'
	assert use3 <= use1 + mb, 'the 47.6 MB frame did not take the pooled span: committed ${use1 / mb} -> ${use3 / mb} MB'
	assert held.len == n3
}

// the rounding itself (vgc_large_round_up, what a drifted request gets): a
// sixteenth of the power of two at or below the request (under a sixteenth of
// the object), nothing under 256 pages or past the pooled sizes; the drift
// case's four sizes are one; a page over a power of two (an array doubled,
// plus its header) rounds by a sixteenth of that power.
fn test_a_large_request_rounds_to_a_sixteenth_of_the_power_of_two_at_or_below_it() {
	assert vgc_large_round_probe(5953) == 6144
	assert vgc_large_round_probe(6007) == 6144
	assert vgc_large_round_probe(6027) == 6144
	assert vgc_large_round_probe(6071) == 6144
	assert vgc_large_round_probe(6144) == 6144
	assert vgc_large_round_probe(4097) == 4352, 'a page over 4096 rounds by 256, a sixteenth of 4096, not by 512: ${vgc_large_round_probe(4097)}'
	assert vgc_large_round_probe(2049) == 2176
	assert vgc_large_round_probe(1025) == 1088
	assert vgc_large_round_probe(257) == 272
	assert vgc_large_round_probe(256) == 256
	assert vgc_large_round_probe(255) == 255, 'under the floor: unrounded'
	assert vgc_large_round_probe(8191) == 8192
	assert vgc_large_round_probe(8192) == 8192
	assert vgc_large_round_probe(8193) == 8193, 'past the pooled sizes: unrounded'
}

// the recurring sizes a run is kept whole for (vgc_pool_keeps_whole through
// vgc_large_recurs_between): a 50 MB frame asked for twice (6401 pages, exact:
// no neighbour of it was asked for) recurs, and any run that still holds it
// is kept from a request below it — a 40 MB request (5120 pages, plus the
// merge floor) against a run of 6401 or 7000 pages — while a run too small
// for it, or a request that leaves no room for it, is not; a size asked for
// once (56 MB, 7169 pages) does not recur. The run itself: a frame merged
// with its free neighbour is a size that never recurs, and the second cut
// kept only a span whose own size did.
fn test_a_run_holding_a_recurring_size_is_kept_for_it() {
	n := 50 * mb // 6400 pages of 8 KB + the array's header: 6401 pages
	assert drop_frame(n) == n
	gc_collect()
	assert drop_frame(n) == n // the size recurs
	gc_collect()
	once := 56 * mb
	assert drop_frame(once) == once // asked for once: does not recur
	gc_collect()
	req := u32(5120 + 16) // the 40 MB request plus the merge floor
	assert vgc_large_recurs_probe(req, 6401), 'the 50 MB frame (6401 pages) does not recur for a 40 MB request against a run of its size'
	assert vgc_large_recurs_probe(req, 7000), 'the 50 MB frame does not recur for a 40 MB request against a run of 7000 pages that holds it'
	assert !vgc_large_recurs_probe(6145, 6400), 'a run of 6400 pages holds no recurring size past the drift case\'s frames (6017 exact, then 6144)'
	assert !vgc_large_recurs_probe(6401, 7100), 'a request of the frame\'s own size leaves no recurring size the run is kept for'
	assert !vgc_large_recurs_probe(6401, 7169), 'the 56 MB frame (7169 pages), asked for once, must not recur'
	assert !vgc_large_recurs_probe(0, 255), 'no size under the rounding floor recurs here'
}
