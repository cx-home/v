// vgc_thread_slot_size_test.v — a live thread's mutator slot (VGC_Cache, one
// per registered thread, in the zero-filled cache chunks) is at most 1,152 B:
// nine of Apple Silicon's 128-byte lines (cx-home/v#77 bar (a)).
//
// Every field of the slot is written by a thread that allocates and blocks
// (the span cache by class, the cold counts, the safe-region register
// snapshot, the stash), so the chunk pages are resident for every live
// thread: the slot is the bulk of what an idle -gc e thread costs over
// -gc none. thr.v (200 threads blocked on a channel, K=20 size classes each,
// v -prod) read on dev2 at 1,920 B a slot (V 69e6a20193 / debb4c6d09): K=20
// 25.9–26.3 KB a thread against -gc none 23.5–23.8 (1.090–1.119 against the
// bar's 1.10); at K=0 18.4 against 16.4, the 2 KB the slot is. 1,920 B was
// alloc[136] span pointers (1,088 B), a 40-word register snapshot (320 B),
// one count byte a class (136 B) and the rest, rounded up to 15 lines.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_thread_slot_size_test.v
module main

const slot_bar = 1152

fn layout_field(layout string, key string) int {
	return layout.all_after('${key}=').all_before(' ').int()
}

fn test_a_thread_slot_is_at_most_nine_lines() {
	layout := vgc_cache_layout()
	rec := layout_field(layout, 'rec')
	assert rec > 0, layout
	assert rec % 128 == 0, 'a slot owns its cache lines (cx-home/v#16): ${rec} B is not a multiple of 128 (${layout})'
	assert rec <= slot_bar, 'a thread slot is ${rec} B, bar ${slot_bar} B (${layout})'
}

// The span cache still answers the span a class allocates from: two threads
// each allocate from many classes, block, wake and allocate again from the
// same classes; every object reads back what was written.
fn fill(id int, ch chan int, done chan bool) {
	mut keep := []string{}
	for k in 0 .. 40 {
		keep << '${id}'.repeat(8 + k * 24)
	}
	_ := <-ch
	for k in 0 .. 40 {
		keep << '${id}'.repeat(8 + k * 24)
	}
	gc_collect()
	for k in 0 .. 80 {
		want := '${id}'.repeat(8 + (k % 40) * 24)
		assert keep[k] == want
	}
	done <- true
}

fn test_the_span_cache_survives_a_block_and_a_collection() {
	ch := chan int{}
	done := chan bool{cap: 8}
	for id in 0 .. 8 {
		spawn fill(id, ch, done)
	}
	for _ in 0 .. 8 {
		ch <- 1
	}
	for _ in 0 .. 8 {
		assert <-done
	}
}
