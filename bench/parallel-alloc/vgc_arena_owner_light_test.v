// vgc_arena_owner_light_test.v — a thread that carves little maps no arena of
// its own (cx-core-code#145).
//
// One arena tail per allocating thread (cx-examples#403, vgc_arena_pick) gave
// every thread that carved a span its own 64 MB arena, also a [par] worker that
// carved a few hundred KB in the whole run. Each such arena costs resident
// memory of its own beside the spans (its page->span map and card table pages,
// the page tables of one more mapping, the touched tail page): fannkuch-redux
// 11 at [par 28] with 1320 tasks read 19.2-19.6 MB peak with 30 arenas and
// 17.4-18.3 MB with VGC_ARENA_OWNER=0 (one arena); at the default width the
// 1320-task bench carried one arena more than the 132-task one and +0.4-0.9 MB
// (cx-core-code#145, cells p145d/p145e). The first-touch contention the rule
// removes is a heavy carver's (28 threads x 480 MB); a thread's first
// vgc_arena_own_bytes (4 MB) of carves come off the shared tails first fit, and
// past that the thread takes an arena of its own as before.
//
// Run: ./v -cc cc test bench/parallel-alloc/vgc_arena_owner_light_test.v
module main

import sync

const nthreads = 8

// light carves ~256 KB of small objects and keeps them live until the end
fn light(n int) int {
	mut keep := [][]u8{cap: n}
	for _ in 0 .. n {
		keep << []u8{len: 256}
	}
	return keep.len
}

// heavy carves `mb` MB in 1 MB pieces, the last half after every heavy thread
// carved its first half, and answers the arena of its last piece; it stays
// live until every heavy thread answered
fn heavy(mb int, mut half sync.WaitGroup, mut done sync.WaitGroup) int {
	mut keep := [][]u8{cap: mb}
	for _ in 0 .. mb / 2 {
		keep << []u8{len: 1024 * 1024}
	}
	half.done()
	half.wait()
	for _ in mb / 2 .. mb {
		keep << []u8{len: 1024 * 1024}
	}
	idx, _ := vgc_arena_probe(keep[keep.len - 1].data)
	done.done()
	done.wait()
	return idx
}

fn test_light_threads_map_no_arena_of_their_own() {
	// the main thread's own carves first: the arenas one thread maps
	base := light(1024)
	arenas0 := vgc_arena_count()
	mut ts := []thread int{}
	for _ in 0 .. nthreads {
		ts << spawn light(1024)
	}
	mut got := 0
	for t in ts {
		got += t.wait()
	}
	arenas1 := vgc_arena_count()
	println('vgc_arena_owner_light: ${nthreads} threads x 256 KB carved, arenas ${arenas0} -> ${arenas1}')
	assert got == nthreads * 1024 && base == 1024
	assert arenas1 == arenas0, '${nthreads} threads of ~256 KB each mapped ${arenas1 - arenas0} arenas of their own (${arenas0} -> ${arenas1})'
}

fn test_heavy_threads_still_carve_arenas_of_their_own() {
	// four threads carving 24 MB each at once: past the bound each carves an
	// arena no other live thread carves (cx-examples#403), so their last pieces
	// lie in four arenas
	mut half := sync.new_waitgroup()
	mut done := sync.new_waitgroup()
	half.add(4)
	done.add(4)
	mut ts := []thread int{}
	for _ in 0 .. 4 {
		ts << spawn heavy(24, mut half, mut done)
	}
	mut seen := map[int]bool{}
	for t in ts {
		seen[t.wait()] = true
	}
	println('vgc_arena_owner_light: 4 threads x 24 MB carved at once, last pieces in arenas ${seen.keys()}')
	assert seen.len == 4, 'four threads of 24 MB each carved their last pieces in ${seen.len} arenas: ${seen.keys()} (one each expected past the light bound)'
}
