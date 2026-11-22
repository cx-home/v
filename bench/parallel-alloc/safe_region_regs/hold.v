// hold.v — the program vgc_safe_region_callee_saved_test.v builds (cx-home/v#88). Each round makes a small heap
// object whose address the main thread keeps only disguised, then hands it to vgc_srr_hold
// (hold.h), which holds it only in a callee-saved register across gc_safe_region_enter, a wait in
// the region, and gc_safe_region_exit. While the main thread waits in the region a second thread
// runs two full collections. After the region the object must still be allocated. The control
// rounds hold nothing (the address stays disguised), and their objects must be freed: that shows
// the collections ran and the measure sees a freed object.
// Prints: done covered=C held_freed=H control_freed=F rounds=R unpublished=U (U: regions that
// ran as ordinary mutators because their snapshot did not fit; cx-home/v#88)
module main

import os

#include "@DIR/hold.h"

fn C.vgc_srr_hold(hold int, disguised u64, mask u64, g voidptr, enter voidptr, leave voidptr) u64
fn C.vgc_srr_covered() int

const mask = u64(0x5a5a_a5a5_3c3c_c3c3)
const obj_len = 256

struct Gate {
mut:
	entered i32
	done    i32
}

@[noinline]
fn make_disguised(r int) u64 {
	b := []u8{len: obj_len, init: u8(r)}
	return u64(voidptr(b.data)) ^ mask
}

// scrub: zero a wide frame below the caller, so no dead slot of make_disguised's frame (which
// held the plain address) is left where the region's frames sit and the stack scan reads
@[noinline]
fn scrub() u64 {
	mut a := [1024]u64{}
	for i in 0 .. 1024 {
		a[i] = 0
	}
	return a[1023]
}

fn collector(g &Gate) {
	for C.vgc_atomic_load_u32(voidptr(&g.entered)) == 0 {
	}
	gc_collect()
	gc_collect()
	C.vgc_atomic_store_u32(voidptr(&g.done), 1)
}

@[noinline]
fn one_round(hold bool, r int) bool {
	d := make_disguised(r)
	_ = scrub()
	g := &Gate{}
	t := spawn collector(g)
	back := C.vgc_srr_hold(if hold { 1 } else { 0 }, d, mask, voidptr(g),
		voidptr(gc_safe_region_enter), voidptr(gc_safe_region_exit))
	t.wait()
	p := if hold { back } else { d ^ mask }
	// freed: the slot's alloc bit is clear (bit 0 of vgc_addr_status)
	return vgc_addr_status(voidptr(p)) & 1 == 0
}

fn main() {
	rounds := os.getenv_opt('ROUNDS') or { '20' }.int()
	mut held_freed := 0
	mut control_freed := 0
	for r in 0 .. rounds {
		if one_round(true, r) {
			held_freed++
		}
		if one_round(false, r) {
			control_freed++
		}
	}
	println('done covered=${C.vgc_srr_covered()} held_freed=${held_freed} control_freed=${control_freed} rounds=${rounds} unpublished=${vgc_safe_unpublished_count()}')
}
