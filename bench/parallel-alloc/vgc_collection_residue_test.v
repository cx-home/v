// vgc_collection_residue_test.v — a collection leaves no heap address in the
// dead stack below its caller (cx-home/v#56, lever 16's c56r stop).
//
// cx-home/v#51 zeroes the dead stack below gc_collect and the collection
// triggers BEFORE the collection's frames are laid down, so the trampoline's
// unwritten slots read zero. The collection's own frames are the other half: the
// mark and the root scan hold heap addresses in registers and spill them into
// frames that are dead once the collection returns, and the program's next
// calls at that depth are carved from them. A slot such a call reserves but
// never writes then holds a heap address the next collection's conservative
// stack scan reads as a root — an object kept one cycle past its death, a
// pooled run that is not pooled. Lever 16 (vgc_stack_candidates, a C function
// of its own) spills the stack words it reads; on the nix clang 21 build of
// c56r's gate, vgc_frame_arena_placement_test's recurring 3000-page frame then
// found a run of its size still held and stayed in the plain arena (red alone
// 3 of 3 in that environment, green under any other compiler, environment or
// layout). The collection now zeroes the dead stack below its caller again on
// the way out (vgc_clear_dead_stack after vgc_run_gc_spilled).
//
// Shape: make_and_collect() holds 64 small buffers and collects; once it has
// returned, heap_words_below() reads the 6 KB below its own frame — where the
// collection's frames were — and counts words inside the arena bounds. None
// may remain.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_collection_residue_test.v
module main

fn C.vgc_real_sp() usize

@[noinline]
fn make_and_collect() int {
	mut keep := [][]u8{}
	for i in 0 .. 64 {
		keep << []u8{len: 4096 + i, init: u8(i)}
	}
	gc_collect()
	return keep.len
}

// heap_words_below counts the words in [sp - 6 KB, sp - 256) whose value lies
// in the arena bounds; it calls nothing while it reads
@[noinline]
fn heap_words_below() int {
	sp := C.vgc_real_sp()
	lo := vgc_arena_lo
	hi := vgc_arena_hi
	mut c := 0
	mut a := sp - 6144
	for a < sp - 256 {
		v := unsafe { *(&usize(a)) }
		if v >= lo && v < hi {
			c++
		}
		a += sizeof(usize)
	}
	return c
}

fn test_a_collection_leaves_no_heap_address_below_its_caller() {
	assert make_and_collect() == 64
	n := heap_words_below()
	assert n == 0, 'the collection left ${n} heap addresses in the dead stack below its caller'
}
