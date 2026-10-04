// vgc_metadata_roots_test.v — the collector's own bookkeeping words are not
// roots (cx-private #1783, batch I-1; the second reader's REDs on 153170d60).
//
// vgc_arena_base_root_test.v covers the arena table. These cases cover the
// rest of the rule, which is that no collector word holding a region address
// roots the object that happens to sit at that address:
//   - a region END. The span-descriptor slab is mmapped directly below a
//     later arena, so `vgc_heap.span_meta_end` equals that arena's base and
//     kept its first object alive. The reader's census found it in 4 of 5
//     runs, and a dropped doubly-linked list then stayed marked.
//   - an object larger than one arena. It gets an arena of its own, so its
//     address is that arena's base. Dropped, it must be reclaimed. Live and
//     held only by an interior pointer, it must survive.
//   - vgc_arena_lo, the lowest arena's base. In a program whose first object
//     is allocated in main, that object sits at vgc_arena_lo.
//
// No cx program can reach the allocator; the cx-gap note is in
// cx-private's batch I-1 RESULTS.md.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_metadata_roots_test.v
module main

const retained_bound = u64(16 * 1024 * 1024)
const big = 70 * 1024 * 1024 // more than one 64 MB arena

@[heap]
struct DNode {
mut:
	prev &DNode = unsafe { nil }
	next &DNode = unsafe { nil }
	pad  [1022]u64
}

@[heap]
struct Holder {
mut:
	inner voidptr
}

@[noinline]
fn scrub_stack() u64 {
	mut buf := [8192]u64{}
	for i in 0 .. buf.len {
		buf[i] = u64(i)
	}
	return buf[8191]
}

fn collect_and_read() u64 {
	_ := scrub_stack()
	gc_collect()
	gc_collect()
	return u64(gc_heap_usage().total_bytes)
}

// Builds a doubly-linked list of ~240 MB. Every node reaches every other, so
// a root at any one node keeps all of it. A thread and a 65 MB carve happen
// mid-build, which places the span slab and further arenas next to each
// other.
@[noinline]
fn build_and_drop_list(n int) int {
	mut first := &DNode{}
	mut cur := first
	for i in 1 .. n {
		mut x := &DNode{
			prev: cur
		}
		cur.next = x
		cur = x
		if i % 7000 == 0 {
			th := spawn fn () int {
				b := []u8{len: 65 * 1024 * 1024}
				return b.len
			}()
			_ := th.wait()
		}
	}
	return n
}

fn test_a_region_end_does_not_root_the_object_at_the_next_arena() {
	for round in 0 .. 3 {
		_ := build_and_drop_list(30000)
		retained := collect_and_read()
		println('vgc_metadata_roots: round ${round} list dropped, retained=${retained} carved=${gc_memory_use()}')
		assert retained < retained_bound, 'round ${round}: ${retained} bytes stay marked after the list was dropped: a collector word equal to an arena base roots it'
	}
}

@[noinline]
fn alloc_and_drop_big() u64 {
	mut sum := u64(0)
	for i in 0 .. 3 {
		mut b := []u8{len: big}
		b[i] = 1
		sum += u64(b.len)
	}
	return sum
}

fn test_dropped_objects_larger_than_an_arena_are_reclaimed() {
	_ := alloc_and_drop_big()
	retained := collect_and_read()
	println('vgc_metadata_roots: oversized dropped, retained=${retained}')
	assert retained < retained_bound, '${retained} bytes stay marked: an object at its own arena base is rooted'
}

@[noinline]
fn make_holder() &Holder {
	mut b := []u8{len: big}
	for i := 0; i < big; i += 4096 {
		b[i] = u8((i >> 12) & 0xff)
	}
	return &Holder{
		inner: unsafe { voidptr(&u8(b.data) + 50 * 1024 * 1024) }
	}
}

@[noinline]
fn churn(n int) int {
	mut s := 0
	for r in 0 .. n {
		mut a := []u8{len: 3 * 1024 * 1024}
		a[r % a.len] = 7
		s += a.len
		mut x := []u8{len: big}
		x[0] = 1
		s += x.len
		gc_collect()
	}
	return s
}

fn test_a_live_object_larger_than_an_arena_held_by_an_interior_pointer_survives() {
	h := make_holder()
	_ := scrub_stack()
	_ := churn(6)
	gc_collect()
	gc_collect()
	mut bad := 0
	base := unsafe { &u8(h.inner) - 50 * 1024 * 1024 }
	for i := 0; i < big; i += 4096 {
		if unsafe { base[i] } != u8((i >> 12) & 0xff) {
			bad++
		}
	}
	println('vgc_metadata_roots: live oversized, bad_pages=${bad} heap=${gc_heap_usage().total_bytes}')
	assert bad == 0
	assert gc_heap_usage().total_bytes >= u64(big), 'the live oversized object was swept'
}
