// card_gate.v — the generated C's write-barrier gate reads the card itself
// (cx-home/v#56 lever 5): a pointer store into a permanent object whose
// page's card is set makes no barrier call. Two records are made permanent
// (vgc_set_permanent, the promotion cycle), the young records are allocated
// up front, and N stores land in each permanent record's pointer field with
// no allocation between them (no stop clears a card): the calls counted
// (-d vgc_wb_count, vgc_wb_calls_count) are one per record's page, the cards
// are set, and the record stored last survives two collections through the
// permanent object alone. Prints `calls=<n> dirty=<a>/<b> bad=<records>`.
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
fn store_all(mut old Rec, ys []&Rec) {
	for y in ys {
		old.a = y
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
	mut old1 := make(-1)
	mut pad := young(2000) // the second record on another page
	mut old2 := make(-2)
	vgc_set_permanent()
	gc_collect() // the promotion cycle: old1 and old2 are permanent
	mut ys := young(n)
	c0 := vgc_wb_calls_count()
	store_all(mut old1, ys)
	store_all(mut old2, ys)
	c1 := vgc_wb_calls_count()
	d1 := vgc_card_dirty(old1)
	d2 := vgc_card_dirty(old2)
	last := ys[n - 1].n
	ys = []&Rec{}
	pad = []&Rec{}
	scrub_stack()
	gc_collect()
	gc_collect()
	mut bad := 0
	for o in [old1, old2] {
		if o.a == unsafe { nil } || o.a.n != last {
			bad++
		}
	}
	println('calls=${c1 - c0} dirty=${d1}/${d2} bad=${bad} pad=${pad.len}')
}
