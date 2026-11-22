// vgc_data_touched_test.v — the data-segment root scan reads only the pages
// the process has touched (cx-home/v#15, cx-private#1886).
//
// A never-written zero-fill .bss page holds no reference, but reading one
// faults a zeroed page in on darwin, so the conservative scan kept the whole
// data segment resident: every cx program carried ~0.8 MB of never-written
// __DATA, and pi-digits read 19.5 MB peak against Python's 9.7 (the 2x bar).
// vgc_touched_ranges (vgc_platform.h) asks mincore(2) which pages are in core
// or paged out and scans only those.
//   - an 8 MB .bss table the program never writes stays out of core across
//     collections (darwin; elsewhere the range is scanned whole, as before);
//   - an object whose only reference sits in a page of that table written just
//     before the collections survives them, and the collections fault in no
//     page of the table beyond the one written.
//   - cx-home/v#85: the same two holds for a 128 MB table — more pages than
//     one 1,024-page mincore block on 4 KB and on 16 KB pages. The first shape
//     asked only when a range fit one block and scanned it whole otherwise, so
//     with 4 KB pages (x86-64) even the 8 MB table was read on every cycle.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_data_touched_test.v
module main

#include "@DIR/vgc_data_touched.h"

fn C.vgc_dt_get(i int) voidptr
fn C.vgc_dt_set(i int, p voidptr)
fn C.vgc_dt_resident_pages() int
fn C.vgc_dt_huge_get(i int) voidptr
fn C.vgc_dt_huge_set(i int, p voidptr)
fn C.vgc_dt_huge_resident_pages() int

@[heap]
struct Payload {
mut:
	tag   u64
	cells []u64
}

@[noinline]
fn scrub_stack() u64 {
	mut buf := [8192]u64{}
	for i in 0 .. buf.len {
		buf[i] = u64(i) ^ 0x5a5a
	}
	return buf[8191]
}

fn churn() int {
	mut n := 0
	for i in 0 .. 20000 {
		s := 'junk-${i}-' + 'y'.repeat(i % 53)
		n += s.len
	}
	return n
}

@[noinline]
fn park_payload(slot int) {
	mut p := &Payload{
		tag:   0xfeed_beef
		cells: []u64{len: 4096, init: u64(index) * 7 + 3}
	}
	C.vgc_dt_set(slot, voidptr(p))
}

fn test_an_untouched_bss_table_stays_out_of_core() {
	before := C.vgc_dt_resident_pages()
	if before < 0 {
		// no paged-out bit here: the range is scanned whole, as before
		return
	}
	for _ in 0 .. 4 {
		_ := churn()
		gc_collect()
	}
	after := C.vgc_dt_resident_pages()
	assert after <= before, 'the collections faulted ${after - before} untouched page(s) of the .bss table in (before ${before}, after ${after})'
}

fn test_an_object_held_only_from_a_freshly_written_page_survives() {
	slot := 600_000 // mid-table: a page nothing else touches
	before := C.vgc_dt_resident_pages()
	park_payload(slot)
	_ := scrub_stack()
	for _ in 0 .. 8 {
		_ := churn()
		gc_collect()
	}
	p := unsafe { &Payload(C.vgc_dt_get(slot)) }
	assert p.tag == 0xfeed_beef, 'the payload held from the .bss table was swept: tag ${p.tag:x}'
	assert p.cells.len == 4096
	for i in 0 .. p.cells.len {
		assert p.cells[i] == u64(i) * 7 + 3, 'cell ${i} was reused: ${p.cells[i]}'
	}
	after := C.vgc_dt_resident_pages()
	if before >= 0 {
		assert after <= before + 1, 'the collections faulted ${after - before - 1} more page(s) of the table in'
	}
}

@[noinline]
fn park_huge_payload(slot int) {
	mut p := &Payload{
		tag:   0xbeef_feed
		cells: []u64{len: 4096, init: u64(index) * 5 + 1}
	}
	C.vgc_dt_huge_set(slot, voidptr(p))
}

// cx-home/v#85
fn test_a_table_larger_than_one_block_stays_out_of_core_and_roots_its_one_written_page() {
	before := C.vgc_dt_huge_resident_pages()
	if before >= 0 {
		for _ in 0 .. 4 {
			_ := churn()
			gc_collect()
		}
		mid := C.vgc_dt_huge_resident_pages()
		assert mid <= before, 'the collections faulted ${mid - before} untouched page(s) of the 128 MB .bss table in (before ${before}, after ${mid})'
	}
	slot := 9_000_000 // past the table's first blocks on either page size
	park_huge_payload(slot)
	_ := scrub_stack()
	for _ in 0 .. 8 {
		_ := churn()
		gc_collect()
	}
	p := unsafe { &Payload(C.vgc_dt_huge_get(slot)) }
	assert p.tag == 0xbeef_feed, 'the payload held from the 128 MB .bss table was swept: tag ${p.tag:x}'
	assert p.cells.len == 4096
	for i in 0 .. p.cells.len {
		assert p.cells[i] == u64(i) * 5 + 1, 'cell ${i} was reused: ${p.cells[i]}'
	}
	after := C.vgc_dt_huge_resident_pages()
	if before >= 0 {
		assert after <= before + 1, 'the collections faulted ${after - before - 1} more page(s) of the 128 MB table in'
	}
}
