// vgc_safe_region_record_size_test.v — the collector's record for one thread
// stays at the size it had before the safe-region register fix: the snapshot
// a thread takes when it enters a GC-safe region costs no more than the 40
// words a jmp_buf needs (vgc_safe_spill_words), on every thread, parked or not.
//
// The record (VGC_Cache, one per registered thread, in vgc_heap's chunks)
// holds the safe-region snapshot inline for the thread's whole life. 5663c161
// fixed a missing root (vgc_safe_region_callee_saved_test) by copying 256
// words of the entry's own frames behind the jmp_buf words: the snapshot grew
// from 40 to 296 words, 2,048 B more on every thread whether it ever enters a
// safe region or not. A program that keeps 4,500 threads parked in channel
// waits paid 9.2 MB for it.
//
// The shape: 256 threads parked in a channel receive (each inside a safe
// region, its snapshot taken), then the main thread reads the record's size
// from vgc_cache_layout. Bound: 1,920 B a record on a 64-bit target, the size
// of the layout with a 40-word snapshot (e8e77367bb). Red on 5663c161: 3,968 B.
//
// Run: ./v -gc e -prod test bench/parallel-alloc/vgc_safe_region_record_size_test.v
module main

const parked = 256
const rec_bound = 1920

fn layout_field(layout string, key string) int {
	for part in layout.split(' ') {
		if part.starts_with(key + '=') {
			return part.all_after('=').int()
		}
	}
	return -1
}

fn park(ch chan int, ready chan int) {
	ready <- 1
	_ := <-ch
}

fn test_safe_region_record_size() {
	ch := chan int{}
	ready := chan int{cap: parked}
	mut ths := []thread{}
	for _ in 0 .. parked {
		ths << spawn park(ch, ready)
	}
	for _ in 0 .. parked {
		_ := <-ready
	}
	layout := vgc_cache_layout()
	rec := layout_field(layout, 'rec')
	ncaches := layout_field(layout, 'ncaches')
	println('record: ${rec} B a thread, ${ncaches} records live (${parked} parked), bound ${rec_bound} B')
	for _ in 0 .. parked {
		ch <- 0
	}
	ths.wait()
	assert ncaches >= parked
	assert rec > 0
	assert rec <= rec_bound, 'a thread record is ${rec} B, over the ${rec_bound} B of a 40-word snapshot layout'
}
