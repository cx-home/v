// vgc_pool_defrag_test.v — a large request is served from a pool of small
// free spans that lie side by side, instead of a fresh arena (cx-private
// #1892).
//
// The pool coalesces a freed span only with neighbours of at least
// vgc_pool_merge_min pages, so a heap that held many size-class objects and
// dropped them pools tens of MB as one- and two-page spans: adjacent, free,
// and unusable for a request of a few hundred pages. vgc_span_alloc then
// carved a fresh 64 MB arena beside them, which is never released — the
// json-codec workload's peak stepped by those pages depending on where in the
// run the emitter's growing buffer met the fragmented pool.
//
// The rule under test: a new-arena carve while the pool holds at least twice
// the request (and an eighth of an arena) is deferred to one collection whose
// sweep merges every run of adjacent pooled spans; the retried request takes
// a run, and the arenas' carved bytes (gc_memory_use) grow by no more than the
// one request the first arena's unused tail holds. Measured: 25,214,976 bytes
// carved for the six requests on 950e84b1e7 (a second arena), 4,202,496 with
// the defrag (the tail; one arena).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_pool_defrag_test.v
module main

const small = 1024
const small_bytes = 48 * 1024 * 1024 // dropped size-class objects: most of an arena
const big = 4 * 1024 * 1024 // the large request (512 pages)

fn fill() int {
	mut keep := [][]u8{cap: small_bytes / small}
	for i in 0 .. small_bytes / small {
		keep << []u8{len: small, init: u8(i)}
	}
	return keep.len
}

fn test_a_large_request_takes_adjacent_free_spans_before_a_new_arena() {
	// The fill runs on its own thread, joined before the collections: once it
	// has exited no scanned stack holds a slot from its frames. Called on this
	// thread, a dead frame's copy of `keep` survived below the collections'
	// frames and the conservative stack scan kept all 48 MB live (marked=55MB
	// after both collections: Linux gcc under `v -stats test`, FreeBSD under
	// tcc on every pin — cx-home/v#17), so there was nothing to merge and the
	// requests carved 25 MB whatever the defrag did.
	n := (spawn fill()).wait()
	gc_collect()
	gc_collect()
	carved0 := gc_memory_use()
	// the arena's unused tail holds one of the requests below; every other one
	// either reuses the pool or carves a new arena
	mut bigs := [][]u8{}
	for i in 0 .. 6 {
		bigs << []u8{len: big, init: u8(i)}
	}
	carved1 := gc_memory_use()
	grew := i64(carved1) - i64(carved0)
	println('vgc_pool_defrag: filled=${n} carved_before=${carved0} carved_after=${carved1} grew=${grew} bigs=${bigs.len}')
	assert bigs.len == 6
	assert grew < 2 * big, 'six ${big}-byte requests carved ${grew} new bytes with ${small_bytes} bytes of adjacent free size-class spans pooled'
}
