// vgc_unaligned_large_false_root_test.v — a large object named only by a word
// that straddles two aligned stack slots is not kept by it (cx-home/cx-platform-store#74).
//
// A thread's stack is scanned at every byte offset (cx-home/v#60): a pointer an
// optimized build spills at an unaligned offset keeps its object. The same scan
// also reads words that no code ever wrote as one value: the high bytes of one
// aligned slot and the low bytes of the next. On macOS the arena sits a few GB
// up, so a small integer in one slot beside zero bytes in the other composes a
// round arena address: store_columnar_test's runner read 0x1_3000_0000 at an
// odd address of main's frame (0x130 << 24) and kept the one 1,114,120 B batch
// buffer the allocator had placed there, 1.1 MB over the live-heap bound
// (store#74 issuecomment-6886353303, -d vgc_rootdiag).
//
// v#60's unaligned spill is a small-object reference (a ?cx.Node's element
// pointer); its test keeps a 64 KB buffer named only at offsets 1..7
// (vgc_unaligned_stack_root_test.v). A byte-offset candidate keeps an object
// up to vgc_unaligned_root_max bytes; a larger one needs an aligned word or a
// register to be kept.
//
// Shape: as vgc_unaligned_stack_root_test.v, with a 1 MB buffer: hide() writes
// its address into its caller's byte array at its seven unaligned offsets and nowhere else,
// one frame under 256 bytes of zeroed frame. After two collections the buffer's
// span is no longer in use (it is pooled or gone).
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_unaligned_large_false_root_test.v
module main

const buf_len = 1024 * 1024

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

// probe reads the address back from the slot and answers its span's pages,
// large-born flag and pooled flag; no aligned copy of the address outlives it
// in the caller's frame (the next offset's buffer can land on the same span)
@[noinline]
fn probe(slot [16]u8, off int) (u32, bool, bool) {
	mut p := u64(0)
	unsafe { C.memcpy(&p, &slot[off], 8) }
	return vgc_span_probe(voidptr(p))
}

fn test_a_large_object_named_only_by_a_straddling_stack_word_is_not_kept() {
	mut tried := 0
	for off in 0 .. 8 {
		gc_collect()
		mut slot := [16]u8{}
		// the word must straddle two aligned slots: skip the offset the array's
		// own alignment makes aligned
		if unsafe { usize(voidptr(&slot[off])) } & (sizeof(usize) - 1) == 0 {
			continue
		}
		tried++
		_ = hide_under_guard(mut slot, off)
		gc_collect()
		gc_collect()
		// the address is read back from the slot only now, after the collections
		hpages, hlarge, hpooled := probe(slot, off)
		assert hpages == 0 || hpooled, 'offset ${off}: a ${buf_len} B buffer named only by a word straddling two stack slots stayed in use: span ${hpages} pages large=${hlarge} pooled=${hpooled}'
		slot = [16]u8{}
	}
	assert tried == 7
}
