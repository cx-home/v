// dummy placeholder for functions from `array_d_gcboehm_opt.v`
// that might be needed for compile time
// `$if gcboehm_opt ? { ... } $else { ... }`
//
// Under vgc (-gc e) the constructors and allocators below are REAL no-scan
// versions (cx-private #1629): cgen emits the `_noscan` family for every
// pointer-free element type under -gc e (`Gen.check_noscan`), and before this
// they all forwarded to the scan versions, so every array buffer sat in a
// scannable span and the conservative marker read its bytes as pointers.
// A no-scan array carries `.noscan_data`; the scan methods it is grown, cloned
// and sliced through (`ensure_cap`, `clone_to_depth`, `push_many`, ...) keep
// that policy via `alloc_array_data_like*`, so the methods below forward. The
// vgc conservative-retention contract (cx #657) holds here too: a zero-cap
// array keeps a real buffer.

module builtin

// these are needed for calls inside `$if gcboehm_opt ? { ... }` in array.v
fn alloc_array_data_noscan(total_size u64) voidptr {
	$if vgc ? {
		raw := vcalloc_noscan(array_data_allocation_size(total_size))
		return unsafe { &u8(raw) + array_data_header_size() }
	}
	return alloc_array_data(total_size)
}

fn alloc_array_data_noscan_uninit(total_size u64) voidptr {
	$if vgc ? {
		raw := unsafe { malloc_noscan_uninit(array_data_allocation_size(total_size)) }
		unsafe {
			(&ArrayDataHeader(raw)).has_slices = false
			return &u8(raw) + array_data_header_size()
		}
	}
	return alloc_array_data_uninit(total_size)
}

// this is needed in `string.v`
fn __new_array_noscan(mylen int, cap int, elm_size int) array {
	$if vgc ? {
		panic_on_negative_len(mylen)
		panic_on_negative_cap(cap)
		cap_ := if cap < mylen { mylen } else { cap }
		total_size := u64(cap_) * u64(elm_size)
		// cx #657: a real buffer even at cap 0 (see __new_array)
		mut data := unsafe { nil }
		if mylen == 0 {
			data = alloc_array_data_noscan_uninit(total_size)
		} else {
			data = alloc_array_data_noscan(total_size)
		}
		return array{
			element_size: elm_size
			data:         data
			len:          mylen
			cap:          cap_
			flags:        .managed | .noscan_data
		}
	}
	return __new_array(mylen, cap, elm_size)
}

fn __new_array_with_default_noscan(mylen int, cap int, elm_size int, val voidptr) array {
	$if vgc ? {
		panic_on_negative_len(mylen)
		panic_on_negative_cap(cap)
		cap_ := if cap < mylen { mylen } else { cap }
		total_size := u64(cap_) * u64(elm_size)
		mut arr := array{
			element_size: elm_size
			len:          mylen
			cap:          cap_
			flags:        .managed | .noscan_data
		}
		// cx #657: a real buffer even at cap 0 (see __new_array)
		if mylen == 0 {
			arr.data = alloc_array_data_noscan_uninit(total_size)
		} else {
			arr.data = alloc_array_data_noscan(total_size)
		}
		if val != 0 {
			mut eptr := &u8(arr.data)
			unsafe {
				if arr.element_size == 1 {
					byte_value := *(&u8(val))
					for i in 0 .. arr.len {
						eptr[i] = byte_value
					}
				} else {
					for _ in 0 .. arr.len {
						vmemcpy(eptr, val, arr.element_size)
						eptr += arr.element_size
					}
				}
			}
		}
		return arr
	}
	return __new_array_with_default(mylen, cap, elm_size, val)
}

fn __new_array_with_multi_default_noscan(mylen int, cap int, elm_size int, val voidptr) array {
	$if vgc ? {
		panic_on_negative_len(mylen)
		panic_on_negative_cap(cap)
		cap_ := if cap < mylen { mylen } else { cap }
		mut arr := array{
			element_size: elm_size
			data:         alloc_array_data_noscan(u64(cap_) * u64(elm_size))
			len:          mylen
			cap:          cap_
			flags:        .managed | .noscan_data
		}
		if val != 0 {
			mut eptr := &u8(arr.data)
			unsafe {
				for i in 0 .. arr.len {
					vmemcpy(eptr, charptr(val) + i * arr.element_size, arr.element_size)
					eptr += arr.element_size
				}
			}
		}
		return arr
	}
	return __new_array_with_multi_default(mylen, cap, elm_size, val)
}

// An element that is itself an array carries a pointer, so cgen never asks
// for this one with a pointer-free element; it stays the scan version.
fn __new_array_with_array_default_noscan(mylen int, cap int, elm_size int, val array, depth int) array {
	return __new_array_with_array_default(mylen, cap, elm_size, val, depth)
}

fn new_array_from_c_array_noscan(len int, cap int, elm_size int, c_array voidptr) array {
	$if vgc ? {
		panic_on_negative_len(len)
		panic_on_negative_cap(cap)
		cap_ := if cap < len { len } else { cap }
		arr := array{
			element_size: elm_size
			data:         alloc_array_data_noscan(u64(cap_) * u64(elm_size))
			len:          len
			cap:          cap_
			flags:        .managed | .noscan_data
		}
		unsafe { vmemcpy(arr.data, c_array, u64(len) * u64(elm_size)) }
		return arr
	}
	return new_array_from_c_array(len, cap, elm_size, c_array)
}

// The methods below forward under every mode: under vgc the scan methods keep
// a `.noscan_data` array's buffer no-scan (`alloc_array_data_like*`).

fn (mut a array) ensure_cap_noscan(required int) {
	a.ensure_cap(required)
}

fn (a array) repeat_to_depth_noscan(count int, depth int) array {
	return unsafe { a.repeat_to_depth(count, depth) }
}

fn (mut a array) insert_noscan(i int, val voidptr) {
	a.insert(i, val)
}

fn (mut a array) insert_many_noscan(i int, val voidptr, size int) {
	unsafe { a.insert_many(i, val, size) }
}

fn (mut a array) prepend_noscan(val voidptr) {
	a.prepend(val)
}

fn (mut a array) prepend_many_noscan(val voidptr, size int) {
	unsafe { a.prepend_many(val, size) }
}

fn (mut a array) pop_left_noscan() voidptr {
	return a.pop_left()
}

fn (mut a array) pop_noscan() voidptr {
	return a.pop()
}

fn (a array) clone_static_to_depth_noscan(depth int) array {
	return a.clone_static_to_depth(depth)
}

fn (a &array) clone_to_depth_noscan(depth int) array {
	return unsafe { a.clone_to_depth(depth) }
}

fn (mut a array) push_noscan(val voidptr) {
	a.push(val)
}

fn (mut a array) push_many_noscan(val voidptr, size int) {
	unsafe { a.push_many(val, size) }
}

fn (a array) reverse_noscan() array {
	return a.reverse()
}

fn (mut a array) grow_cap_noscan(amount int) {
	a.grow_cap(amount)
}

fn (mut a array) grow_len_noscan(amount int) {
	unsafe { a.grow_len(amount) }
}
