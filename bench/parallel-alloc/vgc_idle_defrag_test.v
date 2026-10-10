// vgc_idle_defrag_test.v — requests that grow through the size classes are
// served from the pool's idle one-page spans instead of fresh arena pages
// (cx-home/v#14: the idle-run coalesce).
//
// pi-digits' limbs grow through the size classes: every freed span has the
// page count of a class the program has outgrown, the exact-fit pool never
// hits again, and spans under vgc_pool_merge_min never coalesce at free time
// — so the best-fit split finds no pooled span covering the next class's page
// count and the arena's bump pointer carves fresh pages beside tens of MB of
// idle pooled ones (the hot pool 5 -> 21 MB at a 9 MB goal). The #1892 frag
// gate does not see it: no second arena is ever needed.
//
// The rule under test: an in-arena carve of a pooled size while the pool
// holds at least max(4 MB, 4 x the request) asks the next sweep to merge the
// pool's IDLE runs — spans pooled by an earlier sweep and not re-popped since
// (vgc_idle_defrag_age) — so the next class's requests split those runs. The
// working set re-popped every epoch never qualifies (cx #360's thrash rule).
//
// Shape: 32 MB of 1 KB objects dropped (one-page spans, idle after two
// collections), then five classes of 5-10-page spans, 4 MB a batch, each
// dropped and collected. Without the rule every batch carves its 4 MB (no
// pooled span covers it: the earlier batches' spans are smaller): carved
// grows by five batches. With it the first batch carves (its carve requests
// the merge), the rest split the merged runs: carved grows by one batch
// (measured on 9f4b36efcf: 8,364,032 bytes carved; with the rule 3,391,488 —
// the large `keep` arrays' pooled spans serve part of a batch either way).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_idle_defrag_test.v
module main

const small = 1024
const small_bytes = 32 * 1024 * 1024
const batch_bytes = 4 * 1024 * 1024
// object sizes whose size-class spans are 5, 7, 8, 9 and 10 pages (Go's
// class table: 6784 -> 5, 9472 -> 7, 21760 -> 8, 18432 -> 9, 27264 -> 10) —
// every batch a page count no earlier batch's freed spans fit exactly
const classes = [6784, 9472, 21760, 18432, 27264]

fn fill() int {
	mut keep := [][]u8{cap: small_bytes / small}
	for i in 0 .. small_bytes / small {
		keep << []u8{len: small, init: u8(i)}
	}
	return keep.len
}

fn batch(size int) int {
	n := batch_bytes / size
	mut keep := [][]u8{cap: n}
	for i in 0 .. n {
		keep << []u8{len: size, init: u8(i)}
	}
	return keep.len
}

fn test_growing_classes_split_the_idle_pool_instead_of_carving() {
	n := fill()
	gc_collect()
	gc_collect()
	carved0 := gc_memory_use()
	mut total := 0
	for size in classes {
		total += batch(size)
		gc_collect()
	}
	carved1 := gc_memory_use()
	grew := i64(carved1) - i64(carved0)
	println('vgc_idle_defrag: filled=${n} objects=${total} carved_before=${carved0} carved_after=${carved1} grew=${grew}')
	assert total > 0
	assert grew < batch_bytes * 3 / 2, 'five ${batch_bytes}-byte batches of growing size classes carved ${grew} new bytes beside ${small_bytes} bytes of idle pooled one-page spans'
}
