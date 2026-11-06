// cx-private#1923 (the write barrier's misses): an address in a chunk no arena registered is answered -1,
// without vgc_find_arena's linear scan over every arena — in a concurrent middle each
// pointer store into a C struct, a static or a stack frame scanned the arenas (7.1 % of sql-roundtrips
// k = 1's samples). Drives the white-box self-check in module builtin (vgc_find_arena_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_find_arena_miss_test.v
module main

fn test_an_address_in_no_arena_needs_no_scan() {
	rc := vgc_find_arena_selftest()
	assert rc == 0, 'vgc_find_arena_selftest check ${rc}'
}
