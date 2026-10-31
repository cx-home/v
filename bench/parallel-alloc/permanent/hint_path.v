// hint_path.v — the card barrier's own fast path reads the hint record
// (cx-home/v#56 lever 6; vgc_wb_store, vgc_wb_hp in vlib/builtin): a
// vgc_wb_store call for a store into the hint arena resolves on the record's
// range test and never reaches vgc_wb_store_slow (vgc_find_arena). A []&Rec
// with room for N pointers is made permanent (vgc_set_permanent, the
// promotion cycle), the young records are allocated up front, and N pushes
// land in its buffer through array.push — the bulk mutators call the barrier
// directly on every store, the generated C's gate is not in their path — with
// no allocation between them: under -d vgc_wb_count the calls counted are at
// least N, the slow calls (vgc_wb_slow_calls_count) are 0, the buffer's card
// is set, and the record pushed last survives two collections through the
// permanent buffer alone. Prints `calls=<n> slow=<s> dirty=<d> bad=<b>`.
module main

@[heap]
struct Rec {
mut:
	a &Rec = unsafe { nil }
	n int
}

@[noinline]
fn make(n int) &Rec {
	return &Rec{
		n: n
	}
}

@[noinline]
fn young(n int) []&Rec {
	mut ys := []&Rec{cap: n}
	for i in 0 .. n {
		ys << make(i)
	}
	return ys
}

@[noinline]
fn push_all(mut old []&Rec, ys []&Rec) {
	for y in ys {
		old << y
	}
}

@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

fn main() {
	n := 100000
	mut old := []&Rec{cap: n}
	vgc_set_permanent()
	gc_collect() // the promotion cycle: old's buffer is permanent
	mut ys := young(n)
	c0 := vgc_wb_calls_count()
	s0 := vgc_wb_slow_calls_count()
	push_all(mut old, ys)
	c1 := vgc_wb_calls_count()
	s1 := vgc_wb_slow_calls_count()
	d := vgc_card_dirty(old.data)
	last := ys[n - 1].n
	ys = []&Rec{}
	scrub_stack()
	gc_collect()
	gc_collect()
	mut bad := 0
	if old.len != n || old[n - 1] == unsafe { nil } || old[n - 1].n != last || old[0].n != 0 {
		bad++
	}
	println('calls=${c1 - c0} slow=${s1 - s0} dirty=${d} bad=${bad}')
}
