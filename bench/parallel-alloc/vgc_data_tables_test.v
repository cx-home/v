// vgc_data_tables_test.v — the data-segment root scan (cx-home/v#15 lever 5).
//
//   - vgc_addr_map2 is not a root range. It is lever 3's second arena index per
//     64 MB chunk, a 128 KB table of uint16s like vgc_addr_map, which was always
//     left out; four packed entries read as one word can name a heap address,
//     and scanned, that word rooted the object there for as long as it stood.
//     Here a dropped ~24 MB list is named by such a word: it must be reclaimed.
//   - the scan remembers the pages it has seen touched and asks mincore(2) only
//     about the others (darwin; ~0.46 us a page). An object held only from a page
//     first written after the collector has been running survives, and so does
//     one held only from a page that was already touched and written again.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_data_tables_test.v
module main

#include "@DIR/vgc_data_tables.h"

fn C.vgc_dtab_plant(p voidptr)
fn C.vgc_dtab_unplant()
fn C.vgc_dtab_planted() u64
fn C.vgc_dtab_set(i int, p voidptr)
fn C.vgc_dtab_get(i int) voidptr

const retained_bound = u64(12 * 1024 * 1024)

@[heap]
struct LNode {
mut:
	next &LNode = unsafe { nil }
	tag  u64
	pad  [126]u64
}

@[noinline]
fn scrub_stack() u64 {
	mut buf := [8192]u64{}
	for i in 0 .. buf.len {
		buf[i] = u64(i) ^ 0x5a5a
	}
	return buf[8191]
}

// Builds a ~24 MB singly-linked list and names its head only through the
// planted map2 word.
@[noinline]
fn build_and_plant(n int) {
	mut head := &LNode{
		tag: 1
	}
	mut cur := head
	for i in 1 .. n {
		mut x := &LNode{
			tag: u64(i) + 1
		}
		cur.next = x
		cur = x
	}
	C.vgc_dtab_plant(voidptr(head))
}

fn test_addr_map2_is_not_a_root() {
	gc_collect()
	base := u64(gc_heap_usage().total_bytes)
	build_and_plant(24 * 1024)
	_ := scrub_stack()
	gc_collect()
	gc_collect()
	after := u64(gc_heap_usage().total_bytes)
	assert C.vgc_dtab_planted() != 0, 'the planted word is gone: the case proves nothing'
	C.vgc_dtab_unplant()
	assert after < base + retained_bound, 'a word of vgc_addr_map2 rooted a dropped list: heap ${after} B against ${base} B before it was built'
}

@[heap]
struct Payload {
mut:
	tag   u64
	cells []u64
}

fn churn() int {
	mut n := 0
	for i in 0 .. 20000 {
		s := 'junk-${i}-' + 'z'.repeat(i % 61)
		n += s.len
	}
	return n
}

@[noinline]
fn park(slot int, tag u64) {
	mut p := &Payload{
		tag:   tag
		cells: []u64{len: 4096, init: u64(index) * 5 + tag}
	}
	C.vgc_dtab_set(slot, voidptr(p))
}

fn check(slot int, tag u64) {
	p := unsafe { &Payload(C.vgc_dtab_get(slot)) }
	assert p.tag == tag, 'the payload in slot ${slot} was swept: tag ${p.tag:x}'
	assert p.cells.len == 4096
	for i in 0 .. p.cells.len {
		assert p.cells[i] == u64(i) * 5 + tag, 'slot ${slot} cell ${i} was reused: ${p.cells[i]}'
	}
}

fn test_pages_touched_late_or_again_are_still_scanned() {
	// the collector has run: the touched-page cache is built
	for _ in 0 .. 4 {
		_ := churn()
		gc_collect()
	}
	// a page nothing has touched yet, written now
	park(100_000, 0xa11ce)
	// a page touched before the cycles below (the cache has it), written again later
	park(200_000, 0xb0b)
	_ := scrub_stack()
	for _ in 0 .. 4 {
		_ := churn()
		gc_collect()
	}
	park(200_001, 0xc0de) // same page as slot 200000, after the cache saw it
	_ := scrub_stack()
	for _ in 0 .. 8 {
		_ := churn()
		gc_collect()
	}
	check(100_000, 0xa11ce)
	check(200_000, 0xb0b)
	check(200_001, 0xc0de)
}
