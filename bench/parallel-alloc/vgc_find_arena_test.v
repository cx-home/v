// cx-platform-store#55 (the fourth issue): an address in a chunk no arena touches resolves from the address map —
// no scan of the arena table. The mark asks vgc_find_span for every word inside the arenas' hull; on the store
// daemon at 1,000,000 documents (hundreds of arenas spread over the address space) the words between arenas each
// scanned the whole table, and one forced collection inside a put-docs held the daemon's lock past the clients'
// budgets. Drives the white-box self-check in module builtin (vgc_find_arena_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_find_arena_test.v
module main

fn test_an_address_between_or_beside_the_arenas_is_not_a_table_scan() {
	mut keep := [][]u8{}
	for _ in 0 .. 4 {
		keep << []u8{len: 40 * 1024 * 1024, init: 1}
	}
	rc, probes, scans := vgc_find_arena_selftest()
	assert rc == 0, 'vgc_find_arena_selftest check ${rc}'
	assert probes >= 2, 'only ${probes} empty chunks probed'
	assert scans == 0, '${scans} of ${probes} lookups in a chunk no arena touches scanned the arena table'
	assert keep.len == 4
}
