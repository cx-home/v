// cx-private#1836 L5: at the end of every paced sweep the hot free-span pool
// above a floor (VGC_POOL_FLOOR_KB, default 1 MB) goes back to the OS. The
// aged trim alone waits two cycles and returns at most 128 spans a cycle, so a
// small heap that empties a few MB of spans every cycle kept that pool
// resident (csvr: 1-5 MB pooled after each sweep against 3-4 MB live). This
// churn drops 4 MB of 4 KB buffers per batch; at each collection boundary the
// program sees (the batch in which gc_cycles() moved) the hot pool must read at
// or under the floor plus 512 KB: 40 KB with the return, 3,736 KB without it
// (VGC_POOL_FLOOR_KB=-1, the test's teeth).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pool_floor_test.v
module main

fn batch(n int) int {
	mut keep := [][]u8{cap: n}
	for _ in 0 .. n {
		keep << []u8{len: 4096}
	}
	return keep.len
}

fn test_pool_above_floor_returns_at_each_sweep() {
	// (VGC_POOL_FLOOR_KB=-1 switches the return off: the bound below then
	// fails, which is this test's teeth)
	_, floor, _ := vgc_pool_hot_bytes()
	mut seen := 0
	mut worst := u64(0)
	mut c := gc_cycles()
	for _ in 0 .. 400 {
		assert batch(1024) == 1024 // 4 MB of transients, dropped at return
		if gc_cycles() != c {
			c = gc_cycles()
			hot, _, _ := vgc_pool_hot_bytes()
			if seen > 2 && hot > worst {
				worst = hot
			}
			seen++
		}
		if seen >= 12 {
			break
		}
	}
	assert seen >= 4, 'the churn ran only ${seen} paced collections'
	// the allocation that ran the collection re-pops from the pool, so the
	// read is at or under the floor; the aged trim alone read 3.7 MB here
	assert worst <= floor + u64(512 * 1024), 'hot pool ${worst / 1024} KB at a collection boundary, floor ${floor / 1024} KB'
	println('pool floor ${floor / 1024} KB: worst hot pool at a boundary ${worst / 1024} KB over ${seen} collections')
}
