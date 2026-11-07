// cx-platform-store#55 (the fourth issue): vgc_arena_of answers every address of every arena from
// the address maps — never a scan of the arena table. On the store daemon's 1,000,000-document run
// (13-20 GB heap, ~300 arenas) 85 % of the thread holding the daemon's lock was that scan (the pool's
// split and coalesce ask vgc_arena_of for each span), and every other session waited 10-30 s. Grows
// the heap to several plain arenas, then drives the white-box self-check in module builtin
// (vgc_arena_of_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_arena_of_test.v
module main

fn test_every_arena_address_resolves_from_the_address_maps() {
	mut keep := [][]u8{}
	for _ in 0 .. 8 {
		keep << []u8{len: 40 * 1024 * 1024, init: 1}
	}
	rc, nshared, scans := vgc_arena_of_selftest()
	assert rc == 0, 'vgc_arena_of_selftest check ${rc}'
	assert nshared > 0, 'no probe lies in a chunk whose first map entry names another arena (the layout cannot show the lookup)'
	assert scans == 0, '${scans} of ${nshared} lookups in a shared chunk scanned the arena table'
	assert keep.len == 8
}
