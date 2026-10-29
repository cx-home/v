// vgc_arena_owner_idle_test.v — a thread that stopped carving does not hold an
// arena's tail (cx-examples#403).
//
// One arena tail per allocating thread (vgc_arena_pick) passed over every arena
// a live thread had claimed, also when that thread carved a few spans at start-up
// and then only waited: the one working thread mapped around the idle thread's
// nearly empty 64 MB arena. cx --from=json --to=json on the 300,000-record bench
// document committed 3 arenas where first fit commits 2 (the gate's
// convert.json_300k_arenas row; VGC_ARENA_OWNER=0 read 2). The spec: an owner
// holds its tail only while it carves (it carved in this or the last completed
// cycle); the arena count of one working thread is first fit's.
//
// Run: ./v test bench/parallel-alloc/vgc_arena_owner_idle_test.v
module main

const block = 4096
const live_bytes = 100 * 1024 * 1024

fn work() int {
	n := live_bytes / block
	mut keep := [][]u8{cap: n}
	for _ in 0 .. n {
		keep << []u8{len: block}
	}
	return keep.len
}

fn test_one_working_thread_maps_no_arena_past_first_fit() {
	// the waiting thread's own start-up carve: it claims the first arena
	mut boot := [][]u8{}
	for _ in 0 .. 64 {
		boot << []u8{len: block}
	}
	t := spawn work()
	n := t.wait()
	assert n == live_bytes / block
	assert boot.len == 64
	// 100 MB live: two 64 MB arenas with first fit; a third when the waiting
	// thread's arena tail is passed over
	arenas := vgc_arena_count()
	assert arenas <= 2, '${arenas} arenas for 100 MB live on one working thread (first fit: 2)'
}
