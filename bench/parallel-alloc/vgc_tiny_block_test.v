// vgc_tiny_block_test.v — the tiny allocator packs sub-16-byte noscan objects
// into ONE 16-byte slot, and a packed object never grows into a sibling
// (cx-private #1628).
//
// The tiny allocator carves `vgc_tiny_size` (16) bytes out of a slot of the
// size class of the FIRST object that opened the block. While every size
// mapped one class too high (#1628) that slot was 16 or 24 bytes, so the 16
// carved always fit; with the exact mapping a block opened by an object of
// 1..8 bytes is an 8-byte slot and the next packed object writes into the
// NEXT slot — red with the class fix alone (dev2, 2026-10-03). The block is
// always a 16-byte slot now.
//
// `vgc_realloc` grew a packed object in place whenever the new size fit the
// slot's `elem_size`, measured from the object's own address — so a 4-byte
// object at offset 0 grown to 12 bytes overwrote the siblings packed after
// it. Red at 4660968c34; a packed object always moves now.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_tiny_block_test.v
module main

const n_objs = 20000

// Every packed object keeps its own bytes while thousands of siblings are
// packed beside it.
fn test_packed_tiny_objects_never_overlap() {
	mut ptrs := []voidptr{cap: n_objs}
	mut sizes := []int{cap: n_objs}
	for i in 0 .. n_objs {
		sz := 1 + i % 15
		p := unsafe { malloc_noscan(sz) }
		unsafe { C.memset(p, u8(i % 251), sz) }
		ptrs << voidptr(p)
		sizes << sz
	}
	mut bad := 0
	for i in 0 .. n_objs {
		b := unsafe { &u8(ptrs[i]) }
		for k in 0 .. sizes[i] {
			if unsafe { b[k] } != u8(i % 251) {
				bad++
				break
			}
		}
	}
	assert bad == 0, '${bad} of ${n_objs} tiny objects were overwritten by a sibling'
}

// A packed object grown by realloc moves; its siblings keep their bytes.
fn test_realloc_of_a_packed_object_never_grows_into_its_siblings() {
	mut bad := 0
	for round in 0 .. 1000 {
		a := unsafe { malloc_noscan(4) }
		b := unsafe { malloc_noscan(4) }
		unsafe {
			C.memset(b, 0x5a, 4)
			C.memset(a, u8(round % 200), 4)
		}
		grown := unsafe { v_realloc(a, 12) }
		unsafe { C.memset(grown, 0xa5, 12) }
		for k in 0 .. 4 {
			if unsafe { b[k] } != 0x5a {
				bad++
				break
			}
		}
	}
	assert bad == 0, 'realloc grew a packed tiny object over its sibling in ${bad} of 1000 rounds'
}
