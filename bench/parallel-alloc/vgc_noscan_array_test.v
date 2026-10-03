// vgc_noscan_array_test.v — under -gc e a pointer-free array's buffer is NOT
// scanned: words in a []u8 / []u64 / []i64 / strings.Builder that happen to
// equal heap addresses keep nothing alive (cx-private #1629).
//
// cgen emits the `_noscan` array constructors under -gc e (check_noscan names
// .vgc), but their bodies lived in array_d_gcboehm_opt.v, compiled only under
// -d gcboehm_opt: under vgc `__new_array_noscan` and the rest forwarded to the
// SCAN versions, `alloc_array_data_like` consulted `.noscan_data` only under
// gcboehm_opt, and `vcalloc_noscan` called the scannable `vgc_calloc`. So every
// array buffer sat in a scannable span and the conservative marker read its
// bytes as pointers.
//
// Each shape below writes the addresses of 256 × 64 KiB payloads into a
// pointer-free buffer, drops the payloads' only real root and asks the
// collector what it still marks. Red at 4660968c34 (dev2, 2026-10-03): every
// shape retained the whole 16 MiB. A []voidptr holding the same words is the
// control: it MUST retain them, so the measurement can tell the two apart.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_noscan_array_test.v
// Requires -gc e: `gc_heap_usage().total_bytes` is the bytes vgc MARKED in the
// last collection.
module main

import strings

const payload_count = 256
const payload_bytes = 64 * 1024
const payload_total = i64(payload_count) * payload_bytes

struct Roots {
mut:
	payloads [][]u8
	words    []voidptr
	bytes    []u8
	u64s     []u64
	i64s     []i64
	scan     []voidptr
	sb       strings.Builder
}

fn live_bytes() i64 {
	mut best := i64(0)
	for i in 0 .. 3 {
		gc_collect()
		l := i64(gc_heap_usage().total_bytes)
		if i == 0 || l < best {
			best = l
		}
	}
	return best
}

@[noinline]
fn make_payloads(mut r Roots) {
	r.payloads = [][]u8{cap: payload_count}
	r.words = []voidptr{cap: payload_count}
	for _ in 0 .. payload_count {
		p := []u8{len: payload_bytes, init: 7}
		r.payloads << p
	}
}

// the payload addresses, kept only in a scan array the scenario clears first
@[noinline]
fn take_words(mut r Roots) {
	r.words = []voidptr{cap: payload_count}
	for p in r.payloads {
		r.words << voidptr(p.data)
	}
}

@[noinline]
fn put_word(mut b []u8, at int, w voidptr) {
	x := u64(w)
	for k in 0 .. 8 {
		b[at + k] = u8(x >> (8 * k))
	}
}

// []u8{len: n}: __new_array_with_default_noscan
@[noinline]
fn bytes_by_len(mut r Roots) {
	r.bytes = []u8{len: payload_count * 8}
	for i, w in r.words {
		put_word(mut r.bytes, i * 8, w)
	}
}

// []u8{} grown by `<<` of 8-byte slices: push_many_noscan -> ensure_cap
@[noinline]
fn bytes_by_push(mut r Roots) {
	r.bytes = []u8{}
	for w in r.words {
		mut one := []u8{len: 8}
		put_word(mut one, 0, w)
		r.bytes << one
	}
}

// a literal, then grown by single `<<`: new_array_from_c_array_noscan, push_noscan
@[noinline]
fn bytes_by_literal(mut r Roots) {
	r.bytes = [u8(0), 0, 0, 0, 0, 0, 0, 0]
	for w in r.words {
		x := u64(w)
		for k in 0 .. 8 {
			r.bytes << u8(x >> (8 * k))
		}
	}
}

// a clone of a filled []u8: clone_to_depth(0) keeps the buffer noscan
@[noinline]
fn bytes_by_clone(mut r Roots) {
	mut b := []u8{len: payload_count * 8}
	for i, w in r.words {
		put_word(mut b, i * 8, w)
	}
	r.bytes = b.clone()
	unsafe { C.memset(b.data, 0, b.len) }
}

// []u64{cap: 4} grown by `<<`: push_noscan -> ensure_cap
@[noinline]
fn u64s_by_push(mut r Roots) {
	r.u64s = []u64{cap: 4}
	for w in r.words {
		r.u64s << u64(w)
	}
}

// []i64{len: n} written by index
@[noinline]
fn i64s_by_len(mut r Roots) {
	r.i64s = []i64{len: payload_count}
	for i, w in r.words {
		r.i64s[i] = i64(w)
	}
}

// a strings.Builder (a []u8) grown by write_u8
@[noinline]
fn builder_bytes(mut r Roots) {
	r.sb = strings.new_builder(16)
	for w in r.words {
		x := u64(w)
		for k in 0 .. 8 {
			r.sb.write_u8(u8(x >> (8 * k)))
		}
	}
}

// the control: a pointer array holding the same words
@[noinline]
fn scan_control(mut r Roots) {
	r.scan = []voidptr{cap: payload_count}
	for w in r.words {
		r.scan << w
	}
}

@[noinline]
fn drop_payloads(mut r Roots) {
	r.payloads = [][]u8{}
	r.words = []voidptr{}
}

@[noinline]
fn drop_holders(mut r Roots) {
	r.bytes = []u8{}
	r.u64s = []u64{}
	r.i64s = []i64{}
	r.scan = []voidptr{}
	r.sb = strings.new_builder(0)
}

// retained returns the payload bytes still marked while only the holder's
// words point at them: marked with the holder alive minus marked once it too
// is gone (the holder itself is 2 KiB).
fn retained(fill fn (mut Roots)) i64 {
	mut r := &Roots{}
	make_payloads(mut r)
	take_words(mut r)
	fill(mut r)
	drop_payloads(mut r)
	with_holder := live_bytes()
	drop_holders(mut r)
	without := live_bytes()
	return with_holder - without
}

fn check_noscan(name string, fill fn (mut Roots)) {
	got := retained(fill)
	println('vgc_noscan_array: ${name} retained=${got} of ${payload_total}')
	assert got < payload_total / 4, '${name}: a pointer-free buffer kept ${got} of ${payload_total} payload bytes alive — its words were scanned as pointers'
}

fn test_the_control_a_pointer_array_retains_what_it_points_at() {
	got := retained(scan_control)
	println('vgc_noscan_array: control []voidptr retained=${got} of ${payload_total}')
	assert got > payload_total / 2, 'the control retained only ${got} of ${payload_total}: the measurement cannot see a scanned buffer'
}

fn test_a_u8_buffer_by_len_is_not_scanned() {
	check_noscan('[]u8{len}', bytes_by_len)
}

fn test_a_u8_buffer_grown_by_push_many_is_not_scanned() {
	check_noscan('[]u8 << []u8', bytes_by_push)
}

fn test_a_u8_literal_grown_by_push_is_not_scanned() {
	check_noscan('[u8 literal] << u8', bytes_by_literal)
}

fn test_a_cloned_u8_buffer_is_not_scanned() {
	check_noscan('[]u8.clone()', bytes_by_clone)
}

fn test_a_u64_buffer_grown_by_push_is_not_scanned() {
	check_noscan('[]u64 << u64', u64s_by_push)
}

fn test_an_i64_buffer_by_len_is_not_scanned() {
	check_noscan('[]i64{len}', i64s_by_len)
}

fn test_a_strings_builder_is_not_scanned() {
	check_noscan('strings.Builder', builder_bytes)
}
