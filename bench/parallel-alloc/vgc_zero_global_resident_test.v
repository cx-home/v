// vtest vflags: -enable-globals
// vgc_zero_global_resident_test.v — a global whose value is all zero bytes
// costs no memory until the program writes it (cx-home/cx-core-code#268).
//
// `__global x = T{}` (and `__global x T`) of a T whose every field defaults to
// zero was zeroed in `_vinit` with memset (cx-home/v#32's form). Its storage is
// static, which C already zero-fills, and on darwin and Linux the zero-fill
// pages stay out of core until written — the memset wrote every page of it.
// builtin's vgc_heap is such a global (390,744 B): a cx program that does
// nothing held its ~400 KB resident from start-up (the floor row of
// cx-home/cx-private#1934 against the Go twin), and the memset ran after
// `_vinit`'s first allocations had set the heap up, so the collector set it up
// a second time (two span-table mappings, the first heap's objects unmanaged).
//   - at the test's start no whole page of either global is in core;
//   - a write to one element makes that page resident and reads back.
//
// Run: ./v -gc e -enable-globals test bench/parallel-alloc/vgc_zero_global_resident_test.v
module main

#include "@DIR/vgc_zero_global.h"

fn C.vgc_zg_resident(p voidptr, n usize) int
fn C.vgc_zg_pages(p voidptr, n usize) int

struct ZgBig {
mut:
	a    int
	p    &u8 = unsafe { nil }
	arr  [262144]u64
	flag bool
}

__global zg_big = ZgBig{}
__global zg_big2 ZgBig

fn test_a_zero_global_is_not_written_at_start_up() {
	n := C.vgc_zg_pages(voidptr(&zg_big), sizeof(ZgBig))
	assert n >= 8
	r := C.vgc_zg_resident(voidptr(&zg_big), sizeof(ZgBig))
	r2 := C.vgc_zg_resident(voidptr(&zg_big2), sizeof(ZgBig))
	println('zero globals: zg_big ${r} of ${n} pages resident, zg_big2 ${r2} of ${n}')
	assert r == 0, 'zg_big = ZgBig{}: ${r} of ${n} pages in core before any write (memset in _vinit)'
	assert r2 == 0, 'zg_big2 ZgBig: ${r2} of ${n} pages in core before any write (memset in _vinit)'
}

fn test_a_written_zero_global_reads_back() {
	assert zg_big.a == 0 && zg_big.flag == false && zg_big.arr[131072] == 0
	assert zg_big2.arr[7] == 0 && zg_big2.p == unsafe { nil }
	zg_big.arr[131072] = 42
	zg_big2.arr[7] = 7
	assert zg_big.arr[131072] == 42 && zg_big2.arr[7] == 7
	r := C.vgc_zg_resident(voidptr(&zg_big), sizeof(ZgBig))
	assert r >= 1
}
