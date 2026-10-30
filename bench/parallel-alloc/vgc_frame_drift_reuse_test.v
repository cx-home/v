// vgc_frame_drift_reuse_test.v — a large object's request is rounded up to a
// sixteenth of the power of two above it (vgc_large_round, from 256 pages),
// so a frame that grows by a few pages a period asks for one size and takes
// the last period's pooled span; and a pooled run that still holds a
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

// three periods of a frame that drifts: 47.0, 47.2 and 47.4 MB (6016, 6041
// and 6066 pages) are one rounded size (6144 pages), so the second and the
// third period find the first's span and the committed arena bytes
// (gc_memory_use) hold; before the rounding each size missed the pooled span
// and carved 64 MB of arena.
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
	held := fill(n2)
	use2 := gc_memory_use()
	println('vgc_frame_drift_reuse: committed ${use0 / mb} MB after the 47.0 MB frame, ${use1 / mb} MB after the 47.2 MB frame, ${use2 / mb} MB with the 47.4 MB frame held (${held.len})')
	assert use0 > 0
	assert use1 <= use0 + mb, 'the 47.2 MB frame did not take the 47.0 MB frame\'s span: committed ${use0 / mb} -> ${use1 / mb} MB'
	assert use2 <= use0 + mb, 'the 47.4 MB frame did not take the pooled span: committed ${use0 / mb} -> ${use2 / mb} MB'
	assert held.len == n2
}

// the recurring sizes a run is kept whole for (vgc_pool_keeps_whole through
// vgc_large_recurs_between): a 48 MB frame asked for twice recurs, and any
// run that still holds it is kept from a request below it — a 40 MB request
// (5120 pages, plus the merge floor) against a run of 6656 or 7000 pages —
// while a run too small for it, or a request that leaves no room for it,
// is not; a size asked for once (56 MB) does not recur. The run itself: a
// frame merged with its free neighbour is a size that never recurs, and the
// second cut kept only a span whose own size did.
fn test_a_run_holding_a_recurring_size_is_kept_for_it() {
	n := 48 * mb // 6144 pages of 8 KB + the array's header: a 6656-page request
	assert drop_frame(n) == n
	gc_collect()
	assert drop_frame(n) == n // the size recurs
	gc_collect()
	once := 56 * mb
	assert drop_frame(once) == once // asked for once: does not recur
	gc_collect()
	req := u32(5120 + 16) // the 40 MB request plus the merge floor
	assert vgc_large_recurs_probe(req, 6656), 'the 48 MB frame (6656 pages) does not recur for a 40 MB request against a run of its size'
	assert vgc_large_recurs_probe(req, 7000), 'the 48 MB frame does not recur for a 40 MB request against a run of 7000 pages that holds it'
	assert !vgc_large_recurs_probe(6144, 6655), 'a run of 6655 pages holds no recurring size past the 6144-page frames of the drift case'
	assert !vgc_large_recurs_probe(6656, 7100), 'a request of the frame\'s own size leaves no recurring size the run is kept for'
	assert !vgc_large_recurs_probe(6656, 7680), 'the 56 MB frame (7680 pages once rounded), asked for once, must not recur'
	assert !vgc_large_recurs_probe(0, 255), 'no size under the rounding floor recurs here'
}
