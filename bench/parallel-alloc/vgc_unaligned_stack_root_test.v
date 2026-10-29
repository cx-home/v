// vgc_unaligned_stack_root_test.v — a live object whose only reference is a
// pointer at an unaligned offset of a thread's stack survives a collection
// (cx-home/v#60).
//
// The collector finds a thread's roots by scanning its stack conservatively:
// any value on it that points into the heap keeps its object. An optimized
// build does not keep every pointer word-aligned on the stack. The option
// unwrap copies T through an untyped `byte data[sizeof(T)]`, and clang moved a
// ?cx.Node's bytes 1..23 into spill slots, so the Node's element pointer sat at
// sp+0x407, misaligned by 7, the only reference to a live journal window
// (cx-platform-fabric#10, lldb on an -O2 build). The scan read aligned words
// only, so the collection inside the loop swept the window and the next
// allocation reused its slot.
//
// Shape: hide() allocates a 64 KB buffer (a large object: its own span, never a
// cached one), fills it with 7s and writes its address into its caller's byte
// array at offsets 1..7 — every misalignment — and nowhere else; hide() runs one
// frame under 256 bytes of zeroed frame, so its own dead frame is cleared
// before the collection (vgc_dead_stack_test.v). After gc_collect the buffer's
// span is still in use and the buffer still reads 7s after the next allocation
// of its size.
//
// Run: ./v test bench/parallel-alloc/vgc_unaligned_stack_root_test.v
module main

const buf_len = 64 * 1024

@[noinline]
fn hide(mut slot [16]u8, off int) {
	b := []u8{len: buf_len, init: 7}
	p := u64(voidptr(b.data))
	unsafe { C.memcpy(&slot[off], &p, 8) }
}

@[noinline]
fn hide_under_guard(mut slot [16]u8, off int) u64 {
	mut guard := [32]u64{}
	hide(mut slot, off)
	return guard[31]
}

@[noinline]
fn read_back(slot [16]u8, off int) &u8 {
	mut p := u64(0)
	unsafe { C.memcpy(&p, &slot[off], 8) }
	return unsafe { &u8(voidptr(p)) }
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

fn test_an_unaligned_stack_word_keeps_its_object_across_gc_collect() {
	for off in 1 .. 8 {
		gc_collect()
		before := vgc_span_census()
		mut slot := [16]u8{}
		_ = hide_under_guard(mut slot, off)
		gc_collect()
		after := vgc_span_census()
		assert spans(after, '65544') == spans(before, '65544') + 1, 'offset ${off}: the buffer held only at an unaligned stack offset was swept: census before ${before}, after ${after}'
		// the next allocation of its size must not land on it
		other := []u8{len: buf_len, init: 9}
		p := read_back(slot, off)
		mut sevens := 0
		for i in 0 .. buf_len {
			if unsafe { p[i] } == 7 {
				sevens++
			}
		}
		assert sevens == buf_len, 'offset ${off}: the buffer reads ${sevens} of ${buf_len} sevens after the next allocation'
		assert other[0] == 9
		slot = [16]u8{}
	}
}
