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

// Called from the test function itself, right after the dropping call, so the
// scrub's frame covers the stack the dropping call used (a helper between them
// would leave that region as the helper's own uninitialised slots).
fn collect_and_read() u64 {
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
		_ := scrub_stack()
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
	_ := scrub_stack()
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

// The collector's own clocks and CPU times are integers, not references, but
// a value that falls inside the arenas would root what it points at: the
// collecting thread's CPU time in ns (vgc_gc_cpu_t0, cx-home/v#42) reads
// 0x1_0000_0000-0x2_0000_0000 after 4-8 s of work, where the macOS arenas
// sit, and held an interior address of the streaming bench's dead 100 MiB
// corpus copy: a seventh arena, peak RSS 513 -> 613 MB (cx-private's
// perf-pair red on ffc9f039f). The words a cycle sets before its root scan
// cannot be planted from here, so the case plants the ones a cycle sets after
// it (the same exclusion covers both): the address of a dropped 40 MB buffer,
// planted again before each of the two collections.
const own_mask = u64(0xa5a5000000000000)
const own_big = 40 * 1024 * 1024

@[noinline]
fn own_alloc_and_drop() u64 {
	mut b := []u8{len: own_big}
	for i := 0; i < own_big; i += 4096 {
		b[i] = 1
	}
	return u64(voidptr(unsafe { &b[1000] })) ^ own_mask
}

@[noinline]
fn own_plant(key u64) {
	a := key ^ own_mask
	vgc_gc_last_end = a
	vgc_gate_last_interval = a
	vgc_ph_swalk_ns = a
	vgc_mark_last_ns = a
}

fn test_the_collectors_own_clock_words_do_not_root_what_they_alias() {
	_ := scrub_stack()
	base := collect_and_read()
	key := own_alloc_and_drop()
	_ := scrub_stack()
	own_plant(key)
	_ := scrub_stack()
	gc_collect()
	own_plant(key)
	_ := scrub_stack()
	gc_collect()
	retained := u64(gc_heap_usage().total_bytes)
	println('vgc_metadata_roots: clock words hold a dropped buffer address, base=${base} retained=${retained}')
	assert retained < base + retained_bound, '${retained - base} bytes stay marked: a collector clock word holding an arena address roots the dropped buffer'
}
