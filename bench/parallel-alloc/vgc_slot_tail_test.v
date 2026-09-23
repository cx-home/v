// vgc_slot_tail_test.v — a recycled slot must not carry its previous occupant's
// words into the next object's life (cx-private #1605).
//
// vgc's marker scans every slot of a scannable span CONSERVATIVELY, the whole
// `elem_size` of it: there are no per-object type maps at runtime. So whatever
// words a slot holds beyond what its current occupant wrote are read as
// pointers. Before the fix the allocator zero-filled only the `n` bytes an
// allocation asked for (`vgc_malloc`) or nothing at all (`vgc_memdup`,
// `malloc_uninit`, `vgc_realloc`'s grown region), so a slot recycled from a
// dead object kept that object's pointers in its tail — and a live object
// born there kept alive whatever the dead one pointed at. In cx this chained a
// finished env's parsed module graph from one program to the next, ~13 MB per
// `cx-platform/connector` load, flat under a collector that zero-fills.
//
// The two shapes below are the two ways a live object inherits stale words:
//   * a struct allocated by `memdup` (every `&T{...}`) that is SMALLER than its
//     size class — the tail `[n, elem_size)` is never written;
//   * an array grown by `ensure_cap` — its new buffer comes from
//     `malloc_uninit` and only `[0, len)` is copied, so the spare capacity
//     `[len, cap)` is whatever the slot held before.
// Each builds a pointer-bearing graph whose pointers lead to large payloads
// held alive by a root, drops the graph's holders (the payloads stay live, so
// the dead holders' slots keep valid pointers to them), re-allocates small
// objects over the freed slots and keeps THEM alive, drops the root, and asks
// the collector what it still marks. A payload retained through a stale word
// is the defect; the bound is a quarter of the payload bytes.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_slot_tail_test.v
// Requires -gc e: `gc_heap_usage().total_bytes` is read as the bytes vgc MARKED
// in the last collection. Before the fix (dev2, 2026-09-23): 12.07 MB and
// 8.33 MB of the 16.78 MB of payload retained — red against a 4.19 MB bound.
module main

const payload_count = 256
const payload_bytes = 64 * 1024 // each payload is its own large (noscan) span
const holder_count = 8192

struct Blob {
	data []u8
}

// Victims of both sizes: under the size-class mapping, a 56- and a 64-byte
// object share the 64-byte class with a 48- or 56-byte one, so between them a
// smaller same-class object always leaves the victim's LAST word (its pointer)
// in its unwritten tail.
struct Victim56 {
	w0 u64
	w1 u64
	w2 u64
	w3 u64
	w4 u64
	w5 u64
	p  voidptr
}

struct Victim64 {
	w0 u64
	w1 u64
	w2 u64
	w3 u64
	w4 u64
	w5 u64
	w6 u64
	p  voidptr
}

struct Small48 {
	w0 u64
	w1 u64
	w2 u64
	w3 u64
	w4 u64
	w5 u64
}

struct Small56 {
	w0 u64
	w1 u64
	w2 u64
	w3 u64
	w4 u64
	w5 u64
	w6 u64
}

// Keepers are victims of the same types with NO payload pointer, interleaved
// with the victims and kept alive, so the victims' spans are only PARTLY freed:
// their free slots are recycled in place instead of the whole span going back
// to the page pool (where the OS may hand back zeroes).
struct Roots {
mut:
	blobs   []&Blob
	keepers []voidptr
	victims []voidptr
	arrays  [][]voidptr
	smalls  []voidptr
	grown   [][]voidptr
}

fn live_bytes() u64 {
	mut best := u64(0)
	for i in 0 .. 3 {
		gc_collect()
		l := u64(gc_heap_usage().total_bytes)
		if i == 0 || l < best {
			best = l
		}
	}
	return best
}

@[noinline]
fn make_blobs(mut r Roots) {
	r.blobs = []&Blob{cap: payload_count}
	for _ in 0 .. payload_count {
		r.blobs << &Blob{
			data: []u8{len: payload_bytes, init: 7}
		}
	}
}

@[noinline]
fn make_struct_victims(mut r Roots) {
	r.keepers = []voidptr{cap: 2 * holder_count}
	r.victims = []voidptr{cap: 2 * holder_count}
	for i in 0 .. holder_count {
		b := voidptr(r.blobs[i % payload_count])
		r.victims << voidptr(&Victim56{
			w0: 1
			p:  b
		})
		r.keepers << voidptr(&Victim56{
			w0: 2
		})
		r.victims << voidptr(&Victim64{
			w0: 3
			p:  b
		})
		r.keepers << voidptr(&Victim64{
			w0: 4
		})
	}
}

@[noinline]
fn make_struct_smalls(mut r Roots) {
	r.smalls = []voidptr{cap: 4 * holder_count}
	for _ in 0 .. 2 * holder_count {
		r.smalls << voidptr(&Small48{
			w0: 4
		})
		r.smalls << voidptr(&Small56{
			w0: 5
		})
	}
}

// Every victim array is FULL (len == cap == 8): its buffer's last words point
// at payloads.
@[noinline]
fn make_array_victims(mut r Roots) {
	r.keepers = []voidptr{cap: holder_count}
	r.arrays = [][]voidptr{cap: holder_count}
	for i in 0 .. holder_count {
		mut a := []voidptr{cap: 8}
		mut k := []voidptr{cap: 8}
		for j in 0 .. 8 {
			a << voidptr(r.blobs[(i + j) % payload_count])
			k << voidptr(usize(j + 1))
		}
		r.arrays << a
		r.keepers << voidptr(k.data)
	}
}

// Each grown array pushes to len 5: the buffer ensure_cap allocates for cap 8
// has its elements [5, 8) never written.
@[noinline]
fn make_grown_arrays(mut r Roots) {
	r.grown = [][]voidptr{cap: 2 * holder_count}
	for _ in 0 .. 2 * holder_count {
		mut a := []voidptr{}
		for j in 0 .. 5 {
			a << voidptr(usize(j + 1))
		}
		r.grown << a
	}
}

// retained_after runs one scenario and returns the marked bytes above the
// baseline once the payloads' only root is gone — i.e. what stale words hold.
fn retained_after(make_victims fn (mut Roots), make_reusers fn (mut Roots)) i64 {
	mut r := &Roots{}
	base := live_bytes()
	make_blobs(mut r)
	make_victims(mut r)
	// The holders die; the payloads stay live through r.blobs, so the dead
	// holders' slots are swept with valid payload pointers still in them.
	r.victims = []voidptr{}
	r.arrays = [][]voidptr{}
	live_bytes()
	make_reusers(mut r)
	// The root goes: nothing but a stale word should reach a payload now.
	r.blobs = []&Blob{}
	after := live_bytes()
	retained := i64(after) - i64(base)
	println('[vgc-slot-tail] base=${base} after=${after} retained=${retained} payload=${payload_count * payload_bytes}')
	// keep the live objects live through the measurement
	assert r.keepers.len > 0
	assert r.smalls.len + r.grown.len > 0
	return retained
}

fn test_a_struct_smaller_than_its_class_does_not_root_what_its_slot_held() {
	retained := retained_after(make_struct_victims, make_struct_smalls)
	bound := i64(payload_count) * payload_bytes / 4
	assert retained < bound, 'a recycled slot tail rooted ${retained} bytes of dead payload (bound ${bound}) — #1605'
}

fn test_an_array_s_spare_capacity_does_not_root_what_its_slot_held() {
	retained := retained_after(make_array_victims, make_grown_arrays)
	bound := i64(payload_count) * payload_bytes / 4
	assert retained < bound, 'a grown array spare capacity rooted ${retained} bytes of dead payload (bound ${bound}) — #1605'
}
