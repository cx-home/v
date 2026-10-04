// Refutation: vcalloc_noscan is documented "a noscan span, zero-filled" but a
// sub-16-byte request now takes the tiny allocator, whose packing path returns
// bytes of a block it never zeroes when that block was opened by an UNINIT
// noscan allocation (a zero-cap []u8{}: malloc_noscan_uninit(9)).
module main

@[noinline]
fn dirty_slots() {
	// fill many 16-byte noscan slots with 0xAB and drop them
	mut keep := []voidptr{cap: 20000}
	for _ in 0 .. 20000 {
		p := unsafe { malloc_noscan(16) }
		unsafe { C.memset(p, 0xAB, 16) }
		keep << voidptr(p)
	}
	keep.clear()
}

fn test_vcalloc_noscan_small_is_zero() {
	dirty_slots()
	for _ in 0 .. 3 {
		gc_collect()
	}
	mut bad := 0
	mut arrs := [][]u8{}
	mut ps := []voidptr{}
	for _ in 0 .. 5000 {
		a := []u8{} // opens a tiny block uninit (8-byte header + 1)
		p := vcalloc_noscan(3) // packed at offset 10 of that block
		arrs << a
		ps << voidptr(p)
		unsafe {
			q := &u8(p)
			if q[0] != 0 || q[1] != 0 || q[2] != 0 {
				bad++
			}
		}
	}
	println('TINYZERO nonzero vcalloc_noscan(3) results=${bad} of 5000')
	assert bad == 0
}

// a []u8{len: 3} is 11 bytes: always 8-aligned, so it opens its own block
// (zero-filled) — the array path itself must read zeros.
fn test_small_len_array_is_zero() {
	dirty_slots()
	for _ in 0 .. 3 {
		gc_collect()
	}
	mut bad := 0
	mut keep := [][]u8{}
	for _ in 0 .. 5000 {
		x := []u8{}
		y := []u8{len: 3}
		z := []u16{len: 3}
		if y[0] != 0 || y[1] != 0 || y[2] != 0 || z[0] != 0 || z[2] != 0 {
			bad++
		}
		keep << x
		keep << y
	}
	println('TINYZERO nonzero []u8{len:3}/[]u16{len:3}=${bad} of 5000')
	assert bad == 0
}

// a caller that relies on the zero: string.to_wide (non-Windows branch) writes
// the runes and leaves the u16 terminator to vcalloc_noscan.
fn test_to_wide_is_terminated() {
	dirty_slots()
	for _ in 0 .. 3 {
		gc_collect()
	}
	mut bad := 0
	mut arrs := [][]u8{}
	mut ws := []voidptr{}
	s := 'ab'
	for _ in 0 .. 5000 {
		a := []u8{}
		w := s.to_wide() // vcalloc_noscan(6), packed after the uninit header
		arrs << a
		ws << voidptr(w)
		if unsafe { w[2] != 0 } {
			bad++
		}
	}
	println('TINYZERO unterminated to_wide("ab") results=${bad} of 5000')
	assert bad == 0
}
