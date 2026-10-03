// vgc_size_class_test.v — every small allocation lands in the SMALLEST size
// class that holds it (cx-private #1628).
//
// `vgc_init_size_tables` filled `vgc_s2c8[i]` for size `(i + 1) * 8` and
// `vgc_s2c128[i]` for `1024 + (i + 1) * 128`, while `vgc_size_class` reads
// index `ceil(size / 8)` (resp. `ceil((size - 1024) / 128)`) — the entry for
// one step MORE than the size. So every size that is exactly a class size,
// and every size within one table step below one, landed a whole class up:
// an 8-byte object took a 16-byte slot, 32 → 48, 64 → 80, 1024 → 1152.
// Measured on the fork at 4660968c34 (dev2, 2026-10-03): the table below red
// row by row; after the fix every size 1..32768 is an exact smallest fit.
//
// The allocator's C internals are reached directly: no cx program can call
// them (the cx-gap note is in cx-private's batch I-1 RESULTS.md).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_size_class_test.v
module main

fn C.vgc_size_class(size u32) u8
fn C.vgc_get_class_size(cls int) u32

const max_small = u32(32768)

fn slot_bytes(n u32) u32 {
	return C.vgc_get_class_size(int(C.vgc_size_class(n)))
}

// The issue's table: an exact class size is its own class.
fn test_an_exact_class_size_lands_in_its_own_class() {
	for n in [u32(8), 16, 24, 32, 48, 64, 80, 128, 256, 512, 1024, 1152, 2048, 4096, 8192, 16384,
		32768] {
		got := slot_bytes(n)
		assert got == n, 'size ${n} took a ${got}-byte slot'
	}
	// sizes between two classes take the upper one, and no more
	assert slot_bytes(1) == 8
	assert slot_bytes(9) == 16
	assert slot_bytes(40) == 48
	assert slot_bytes(1025) == 1152
	assert slot_bytes(1153) == 1280
}

// Every small size: the slot holds it, and the class below does not.
fn test_every_small_size_takes_the_smallest_class_that_holds_it() {
	mut wrong := 0
	mut first := u32(0)
	for n := u32(1); n <= max_small; n++ {
		cls := int(C.vgc_size_class(n))
		got := C.vgc_get_class_size(cls)
		below := if cls > 1 { C.vgc_get_class_size(cls - 1) } else { u32(0) }
		if got < n || below >= n {
			if wrong == 0 {
				first = n
			}
			wrong++
		}
	}
	assert wrong == 0, '${wrong} sizes of 1..${max_small} are not in their smallest class (first: ${first} -> ${slot_bytes(first)})'
}
