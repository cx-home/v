// perm_transient.v — what a program holds at its first collection is not
// promoted unless it asks (cx-home/v#15): a permanent object is never swept,
// so an automatic promotion at the first cycle made the program's in-flight
// data immortal (cx-private's bench/repr read +1.0 input copy on its xml, cx
// and cxel formats on fe3095ab6). The transient here is ~8 MB of 64-byte
// strings, held across the first gc_collect, then dropped; the live heap after
// two more collections is printed as `after_kb=`.
module main

@[noinline]
fn hold_transient(n int) int {
	mut xs := []string{cap: n}
	for i in 0 .. n {
		xs << 'transient-record-${i:08}-'.repeat(2)
	}
	gc_collect() // the first cycle: the transient is live here
	mut total := 0
	for x in xs {
		total += x.len
	}
	return total
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
	before := gc_heap_usage().total_bytes
	total := hold_transient(120000)
	scrub_stack()
	gc_collect()
	gc_collect()
	after := gc_heap_usage().total_bytes
	held_kb := if after > before { (after - before) / 1024 } else { usize(0) }
	println('transient_bytes=${total} before_kb=${before / 1024} after_kb=${after / 1024} held_kb=${held_kb}')
}
