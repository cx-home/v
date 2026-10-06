// vgc_arena_sized_drop_test.v — a dropped buffer of an arena's size or more is
// reclaimed (cx-private #1756).
//
// A buffer of 64 MB or more takes an arena of its own, so the object sits at
// the arena's base, and the arena table — scanned with the data segments —
// held that address: twelve dropped 64 MB buffers stayed marked, 805 MB after
// the final collections, while 60 MB ones were reclaimed. The arena-base fix
// (vgc_arena_base_root_test.v, cx-private #1783) closed it: red on 72608d53b
// (marked 805306733 bytes), green from 4f32d3ee0 (under 1 KB). This is the
// issue's own shape, kept as the regression for the oversized-arena case.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_arena_sized_drop_test.v
module main

const mb = 1024 * 1024

@[noinline]
fn big(n int) int {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = 1
	}
	return b.len
}

@[noinline]
fn smalls(k int) int {
	mut s := 0
	for r in 0 .. k {
		mut a := []string{}
		for i in 0 .. 1000 {
			a << 'x${i}-${r}'
		}
		s += a.len
	}
	return s
}

fn test_dropped_arena_sized_buffers_are_reclaimed() {
	mut x := 0
	for i in 0 .. 12 {
		x += big(64 * mb)
		x += smalls(50)
		if i % 3 == 2 {
			gc_collect()
		}
	}
	for _ in 0 .. 3 {
		x += smalls(100)
		gc_collect()
	}
	u := gc_heap_usage()
	assert x > 0
	// the twelve buffers are 768 MB; one still marked would be 64 MB
	assert u.total_bytes < 16 * mb, 'marked ${u.total_bytes} bytes after the drops'
	assert u.heap_size < 64 * mb, 'in-use spans ${u.heap_size} bytes after the drops'
}
