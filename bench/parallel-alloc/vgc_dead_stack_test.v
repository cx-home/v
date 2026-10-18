// vgc_dead_stack_test.v — an explicit collection keeps nothing that a returned
// frame left in the dead stack below its caller (cx-home/v#51).
//
// The collector scans the collecting thread's stack conservatively from the
// register-spilling trampoline's frame to the top. The frames between the
// caller and the trampoline (gc_collect and the runtime calls under it, the
// trampoline's jmp_buf, whose signal-mask words setjmp leaves unwritten) are
// laid on stack that earlier calls at that depth used: a slot they reserve but
// never write still holds what a returned call put there, and the scan reads it
// as a root. vgc_parallel_sweep_test's one-walker child read one span more than
// its twin run (CI 39107667199, fork fix/gaps2-v51-state): a dropped node at
// the second arena's base (0x7f7100000000, also the first arena's end, a value
// an allocation can leave in its frames) marked in the last cycle, held
// by no word once the child's later calls had written over the stack, keeping
// its 1 KB buffer's span (census 1152:0/1641/0 against 1640). gc_collect and
// the collection triggers now zero the dead stack below them before the
// collection's frames are laid down (vgc_clear_dead_stack, vgc_platform.h).
//
// Shape: leave() fills 8 KB of its own frame with the address of a 64 KB
// buffer nothing keeps (a large object: its own span, never a cached one) and
// returns; the test then collects from the same depth. The buffer's span must
// be gone. Before the fix it stayed, marked, held by no word (dev2 3 of 3).
//
// Run: ./v test bench/parallel-alloc/vgc_dead_stack_test.v
module main

const dead_words = 1024

@[noinline]
fn fill(p &u64, n int, v u64) {
	for i in 0 .. n {
		unsafe {
			p[i] = v
		}
	}
}

// leave writes the address of a buffer nothing keeps into 8 KB of its frame
@[noinline]
fn leave() {
	b := []u8{len: 64 * 1024, init: 7}
	mut a := [1024]u64{}
	fill(&a[0], dead_words, u64(voidptr(b.data)))
}

// spans answers the in-use span count of one object size in the census
fn spans(census string, size string) int {
	for e in census.split(' ') {
		if e.all_before(':') == size {
			mut n := 0
			for f in e.all_after(':').split('/') {
				n += f.int()
			}
			return n
		}
	}
	return 0
}

fn test_a_dead_frame_keeps_nothing_across_gc_collect() {
	gc_collect()
	before := vgc_span_census()
	leave()
	gc_collect()
	after := vgc_span_census()
	assert spans(after, '65544') == spans(before, '65544'), 'a returned frame kept its buffer: census before ${before}, after ${after}, holders ${vgc_orphan_holders([]usize{},
		65544)}'
}
