// vgc_atomics_semantics_test.v — every compiler arm of vgc_platform.h's atomics
// answers what the GCC/Clang arm answers (cx-home/v#22): add/sub return the NEW
// value, a failed CAS writes the observed word into *expected, exchange and
// fetch_or/fetch_and return the OLD value. The msvc arm returned the OLD value
// from add, so the parallel-mark pool's first thread took the collector's slot 0
// and live objects were swept (mt_sound T=8 access violation under msvc).
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_atomics_semantics_test.v
//      ./v -cc msvc -gc e test bench/parallel-alloc/vgc_atomics_semantics_test.v
module main

@[heap]
struct Cells {
mut:
	w u32
	q u64
	b u8
}

fn test_add_and_sub_answer_the_new_value() {
	mut c := &Cells{}
	c.w = 5
	assert C.vgc_atomic_add_u32(&c.w, 1) == 6
	assert C.vgc_atomic_sub_u32(&c.w, 2) == 4
	assert c.w == 4
	c.q = u64(1) << 40
	assert C.vgc_atomic_add_u64(&c.q, 3) == (u64(1) << 40) + 3
	assert C.vgc_atomic_sub_u64(&c.q, 4) == (u64(1) << 40) - 1
	assert C.vgc_atomic_load_u64(&c.q) == (u64(1) << 40) - 1
}

fn test_cas_success_and_failure_write_back() {
	mut c := &Cells{}
	c.w = 7
	mut expected := u32(7)
	assert C.vgc_atomic_cas_u32(&c.w, &expected, u32(9))
	assert C.vgc_atomic_load_u32(&c.w) == 9
	expected = 7
	assert !C.vgc_atomic_cas_u32(&c.w, &expected, u32(11))
	assert expected == 9, 'a failed CAS writes the observed word into *expected'
	assert c.w == 9
}

fn test_exchange_and_bit_ops_answer_the_old_value() {
	mut c := &Cells{}
	c.w = 3
	assert C.vgc_atomic_exchange_u32(&c.w, u32(8)) == 3
	assert c.w == 8
	c.b = 0b0101
	assert C.vgc_atomic_fetch_or_u8(&c.b, u8(0b0010)) == 0b0101
	assert C.vgc_atomic_fetch_and_u8(&c.b, u8(0b0110)) == 0b0111
	assert c.b == 0b0110
	C.vgc_atomic_fence()
}

fn test_concurrent_adds_hand_out_distinct_tickets() {
	mut c := &Cells{}
	mut ths := []thread []u32{}
	for _ in 0 .. 8 {
		ths << spawn fn (mut c Cells) []u32 {
			mut got := []u32{cap: 1000}
			for _ in 0 .. 1000 {
				got << C.vgc_atomic_add_u32(&c.w, 1)
			}
			return got
		}(mut c)
	}
	mut seen := map[u32]bool{}
	for t in ths {
		for v in t.wait() {
			assert v !in seen
			seen[v] = true
		}
	}
	assert seen.len == 8000
	assert 0 !in seen, 'add answers the NEW value: tickets are 1..8000'
	assert 8000 in seen
}
