// perm_epoch.v — vgc_set_permanent's epoch (cx-home/v#15): the promotion
// cycle promotes what was allocated BEFORE the call and is still held, never
// what the program allocates after it. 20,000 records are built, the call is
// made, then ~6 MB of strings is held across the next collections and dropped;
// every record then takes a fresh young record through a field (a store into a
// permanent object) and is read back after two collections. Prints
// `bad=<records not intact> after_kb=<live heap>`: the dropped strings must
// not be in after_kb (VGC_PERM=0 gives the reference figure).
module main

struct Rec {
mut:
	a &Rec = unsafe { nil }
	s string
	n int
}

@[noinline]
fn build_old(n int) []&Rec {
	mut xs := []&Rec{cap: n}
	for i in 0 .. n {
		xs << &Rec{
			s: 'old-${i:06}'
			n: i
		}
	}
	return xs
}

@[noinline]
fn hold_transient(n int) int {
	mut xs := []string{cap: n}
	for i in 0 .. n {
		xs << 'transient-record-${i:08}-'.repeat(2)
	}
	gc_collect()
	mut t := 0
	for x in xs {
		t += x.len
	}
	return t
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
	mut olds := build_old(20000)
	vgc_set_permanent()
	t := hold_transient(120000)
	for i in 0 .. olds.len {
		olds[i].a = &Rec{
			s: 'young-${i}'
			n: -i
		}
	}
	scrub_stack()
	gc_collect()
	gc_collect()
	mut bad := 0
	for i, o in olds {
		if o.n != i || o.a == unsafe { nil } || o.a.n != -i || o.a.s != 'young-${i}' {
			bad++
		}
	}
	println('transient_bytes=${t} bad=${bad} after_kb=${gc_heap_usage().total_bytes / 1024}')
}
