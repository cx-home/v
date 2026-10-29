// vgc_arena_owner_test.v — one arena tail per allocating thread
// (cx-examples#403).
//
// With first fit every thread carved its new spans from the same arena's
// tail, so threads first-touched fresh pages of one mapping in turn; on macOS
// those faults serialize in the kernel: 28 threads x 480 MB in 1 MB pieces of
// shared 64 MB mappings spent 26.4 s of system time, in mappings of their own
// 4.0 s, and 28 xlsx parses in one process read 21-23 s of system time against
// 1.5-2.2 s for 12. Drives the white-box self-check in module builtin
// (vgc_arena_owner_selftest: vgc_arena_pick on a table of four arenas, and
// on two arenas whose owner stopped carving).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_arena_owner_test.v
module main

fn test_a_thread_never_carves_another_live_threads_arena_tail() {
	rc := vgc_arena_owner_selftest()
	assert rc == 0, 'vgc_arena_owner_selftest check ${rc}'
}
