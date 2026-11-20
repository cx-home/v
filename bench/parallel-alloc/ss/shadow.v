// shadow.v — the program vgc_shadow_stack_test.v builds with -d vgc_shadow_stack
// (cx-home/v#74, option (a), the shadow stack). Modes:
//   MODE=none        allocate a 64 KB buffer and drop it; plant nothing.
//   MODE=plant OFF=n plant the dropped buffer's address at byte offset n of a
//                    [16]u8 local of main's live frame, never read it back
//                    (prof-052's false root: bytes of a live frame spelling an
//                    address inside a dropped object).
//   MODE=typed       the #60 shape in V types: a ?Node whose element pointer is
//                    the only reference to a live 64 KB buffer, unwrapped and
//                    held across two collections, then read.
// The buffer's address is kept between collections only XOR-masked in a global,
// so nothing but the plant can root it. After two gc_collect calls the program
// prints `ss mode=<m> off=<n> kept=<0|1> sevens=<n>`.
module main

import os

const buf_len = 64 * 1024
const mask = u64(0x5a5a_5a5a_5a5a_5a5a)

__global masked = u64(0)

struct Node {
	kind u8
	tag  u8
	data []u8
}

@[noinline]
fn drop_one() {
	b := []u8{len: buf_len, init: 7}
	masked = u64(voidptr(b.data)) ^ mask
}

@[noinline]
fn drop_under_guard() u64 {
	mut guard := [32]u64{}
	drop_one()
	return guard[31]
}

@[noinline]
fn plant(mut slot [16]u8, off int) {
	p := masked ^ mask
	unsafe { C.memcpy(&slot[off], &p, 8) }
}

@[noinline]
fn make_node(k u8) ?Node {
	if k == 0 {
		return none
	}
	return Node{
		kind: k
		tag:  k + 1
		data: []u8{len: buf_len, init: 7}
	}
}

@[noinline]
fn sevens_of(d []u8) int {
	mut n := 0
	for i in 0 .. d.len {
		if d[i] == 7 {
			n++
		}
	}
	return n
}

@[noinline]
fn kept() int {
	pages, _, pooled := vgc_span_probe(voidptr(masked ^ mask))
	return if pages > 0 && !pooled { 1 } else { 0 }
}

@[noinline]
fn typed() int {
	nd := make_node(u8(os.args.len)) or { return -1 }
	gc_collect()
	other := []u8{len: buf_len, init: 9}
	gc_collect()
	return if nd.kind == 1 && other[0] == 9 { sevens_of(nd.data) } else { -2 }
}

fn main() {
	mode := os.getenv_opt('MODE') or { 'none' }
	off := (os.getenv_opt('OFF') or { '0' }).int()
	gc_collect()
	mut slot := [16]u8{}
	mut sevens := -1
	match mode {
		'typed' {
			sevens = typed()
		}
		else {
			_ = drop_under_guard()
			if mode == 'plant' {
				plant(mut slot, off)
			}
			gc_collect()
			gc_collect()
		}
	}
	k := if mode == 'typed' { 0 } else { kept() }
	println('ss mode=${mode} off=${off} kept=${k} sevens=${sevens} slot=${slot[0]}')
}
