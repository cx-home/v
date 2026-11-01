// vgc_cold_neighbour_merge_test.v — a freed large run joins its COLD pooled
// neighbour at its free (cx-home/v#58; vgc_pool_states_meet and
// vgc_pool_go_cold_for in vlib/builtin/vgc_d_vgc.c.v): the run is returned
// to the OS first, so the two are one cold run a later request takes, where
// before a hot run beside a trimmed one stayed separate until its own trim
// and a request the two together would have served carved an arena while
// 25–176 MB sat pooled (measure/collector-epic-64, the carve lines).
//
// The shape (pages of 8 KB; the array's header adds one to each): a
// 3000-page frame and a 2900-page one above it, carved from the tail (two
// sizes asked for once each: a run of a recurring size keeps its size and
// joins nothing, vgc_pool_keeps_size), then a
// 1 MB separator held so the upper frame merges with nothing above it. The
// upper frame is dropped and four collections run: the trim returns its run
// to the OS after two (vgc_pool_trim_age). Then the lower frame is dropped
// and a collection runs: its run is freed beside the cold run. A 5500-page
// request follows: the arena's tail (8192 pages less the two frames and the
// separator) cannot hold it, so on 14dfcca7f — the hot run and the cold run
// apart, 3000 and 2900 pages — it carves a second arena; now the merged
// 5900-page cold run serves it and the arena count holds. Its own process (a fresh
// heap: one arena).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_cold_neighbour_merge_test.v
module main

const mb = 1024 * 1024
const page = 8192 // vgc's page

@[noinline]
fn fill(n int) []u8 {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = u8(i)
	}
	return b
}

@[noinline]
fn drop_frame(n int) int {
	return fill(n).len
}

@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

fn test_a_freed_run_joins_its_cold_neighbour() {
	mut lower := fill(3000 * page) // held: the lower frame
	assert drop_frame(2900 * page) == 2900 * page // the upper frame, dropped (its own size: the two runs merge)
	sep := fill(mb) // held: nothing merges with the upper frame's run from above
	scrub_stack()
	gc_collect() // the upper run is pooled, hot
	gc_collect()
	gc_collect()
	gc_collect() // the trim has returned it to the OS (vgc_pool_trim_age = 2)
	arenas0 := vgc_arenas_count()
	// the two frames share a frame arena (cx-home/v#58, vgc_frame_pages: a
	// request of a quarter arena or more), the separator the plain one
	assert arenas0 == 2, 'the two frames did not fit one frame arena beside the plain one: ${arenas0}'
	lower = []u8{}
	scrub_stack()
	gc_collect() // the lower run is freed beside the cold run: one 5900-page cold run
	big :=
		fill(5500 * page) // takes the merged run; apart, the two runs are 3000 and 2900 pages and the tail is short of it
	arenas1 := vgc_arenas_count()
	println('vgc_cold_neighbour_merge: arenas ${arenas0} -> ${arenas1} after a 5500-page request beside a freed 3000-page run and a cold 2900-page run (${sep.len} ${big.len} ${lower.len})')
	assert arenas1 == arenas0, 'the 5500-page request carved an arena: the freed run did not join its cold neighbour (${arenas0} -> ${arenas1})'
}
