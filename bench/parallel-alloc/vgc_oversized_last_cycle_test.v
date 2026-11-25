// cx-private#2052 (k-nucleotide's last ~41 MB) — an oversized buffer dropped
// before a program's LAST collection must leave the resident set in that
// collection when the committed span pages are past the goal.
//
// bf2adb3926 decommits idle oversized spans from the carve side: a carve past
// the goal compensates from them first. But a program can stop carving: once
// its small-object pool is warm, its allocation is served by swept spans and
// no carve comes. Then the only path left is vgc_pool_trim, which takes an
// oversized span only once it is vgc_pool_trim_age (2) cycles old. k-nucleotide
// 25 M (dev2, the bf2adb3926 kit) ends in two modes: in one, a carve after the
// last cycle triggers compensation, which decommits 137 MB of oversized spans
// (peak 597 MB). In the other, no carve follows the last cycle, and 119 MB of
// oversized spans stay hot to exit (peak 714-720 MB; pbm1 reads 720.70 x3).
//
// The test warms a small-object churn, then drops a 160 MB buffer. It keeps
// churning until ONE natural collection has completed (gc_cycles() + 1, never
// gc_collect(), which returns the whole pool). It then reads the bytes the
// trim returned (gc_heap_usage().unmapped_bytes): they must have grown by at
// least half the buffer.
module main

const mb = 1024 * 1024
const big_len = 160 * mb
const keep_len = 24 * mb

struct Node {
	next &Node = unsafe { nil }
	pad  [6]u64
}

// churn drops n chains of 256 64-byte nodes (garbage only the collector finds;
// the RC front line frees a lone buffer at once, never a chain's tail)
fn churn(n int, salt int) u64 {
	mut s := u64(0)
	for _ in 0 .. n {
		mut head := &Node(unsafe { nil })
		for _ in 0 .. 256 {
			head = &Node{
				next: head
			}
		}
		s += u64(salt)
		s += head.pad[0]
	}
	return s
}

// hold_big touches a big_len buffer and drops it on return: in its own frame,
// so no stale slot of the test's frame keeps it marked
@[noinline]
fn hold_big(n int) u64 {
	mut big := []u8{len: big_len, init: u8(n)}
	big[n] = 9
	return big[big_len - 1] + big[n]
}

fn test_an_oversized_buffer_dropped_before_the_last_collection_leaves_in_it() {
	keep := []u8{len: keep_len, init: 7}
	mut sink := churn(4000, 1) // the small pool warm: several cycles of 64 B chains
	c0 := gc_cycles()
	sink += hold_big(3)
	sink += churn(10, 2)
	c1 := gc_cycles()
	un0 := gc_heap_usage().unmapped_bytes
	mut n := 0
	for gc_cycles() < c1 + 1 && n < 400 {
		sink += churn(50, n)
		n++
	}
	c2 := gc_cycles()
	un1 := gc_heap_usage().unmapped_bytes
	returned := if un1 > un0 { un1 - un0 } else { usize(0) }
	println('vgc_oversized_last_cycle: big=${big_len} cycles ${c0} -> ${c1} -> ${c2} (churn rounds ${n}) unmapped ${un0} -> ${un1} returned=${returned} returned_over_big=${f64(returned) / f64(big_len):.3f} keep=${keep[0]} sink=${sink}')
	assert c2 > c1, 'no collection ran while the churn went on'
	assert returned >= usize(big_len / 2), 'the collection after an oversized buffer was dropped returned ${returned} bytes of ${big_len}: the idle oversized span stayed resident (age-gated trim, no carve to compensate)'
}
