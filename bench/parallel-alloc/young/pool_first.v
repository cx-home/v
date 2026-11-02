// pool_first.v — nine waves of 400,000 48-byte records, each wave a chain
// built record by record (every record live until the wave's sum is read, so
// the allocations escape: the first shape kept nothing of a record and read
// one page committed over nine waves), dropped and collected twice: under the
// young regime with the nursery (VGC_YOUNG=1) a class span comes from the
// pool before the nursery's fresh carve, so the committed bytes
// (gc_memory_use: the arenas' carved bytes, the nursery's among them) level
// off after the first wave (cx-home/v#56 lever 7; vgc_central_get_fresh in
// vlib/builtin/vgc_d_vgc.c.v). Prints committed=<after wave 1> <after wave 9>
// wave=<bytes of one wave's records>.
module main

struct Rec {
mut:
	a u64
	b u64
	c u64
	d u64
	p &Rec = unsafe { nil }
}

const n = 400000

@[noinline]
fn wave() u64 {
	mut head := &Rec(unsafe { nil })
	for i in 0 .. n {
		head = &Rec{
			a: u64(i)
			p: head
		}
	}
	mut s := u64(0)
	for r := head; r != unsafe { nil }; r = r.p {
		s += r.a
	}
	return s
}

// the wave's chain head off the stack's roots before the collection
@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

fn main() {
	mut sum := wave()
	scrub_stack()
	gc_collect()
	gc_collect()
	c1 := gc_memory_use()
	for _ in 0 .. 8 {
		sum += wave()
		scrub_stack()
		gc_collect()
		gc_collect()
	}
	c9 := gc_memory_use()
	println('committed=${c1} ${c9} wave=${u64(n) * 48} sum=${sum}')
}
