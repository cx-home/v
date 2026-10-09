// diag (cx-home/v#17): does a MAP_FIXED anonymous replace drop RSS here?
module main

import runtime

#include <sys/mman.h>

fn C.mmap(addr voidptr, len usize, prot int, flags int, fd int, off i64) voidptr
fn C.madvise(addr voidptr, len usize, advice int) int

fn rss() u64 {
	return runtime.used_memory() or { 0 }
}

fn main() {
	n := usize(64 * 1024 * 1024)
	r0 := rss()
	p := C.mmap(unsafe { nil }, n, C.PROT_READ | C.PROT_WRITE, C.MAP_PRIVATE | C.MAP_ANON, -1, 0)
	mut b := unsafe { &u8(p) }
	for i := usize(0); i < n; i += 4096 {
		unsafe {
			b[i] = 1
		}
	}
	r1 := rss()
	q := C.mmap(p, n, C.PROT_READ | C.PROT_WRITE, C.MAP_PRIVATE | C.MAP_ANON | C.MAP_FIXED, -1, 0)
	r2 := rss()
	println('mapfixed: rss0=${r0 / 1024} KB touched=${r1 / 1024} KB after_map_fixed=${r2 / 1024} KB same_addr=${q == p}')
	for i := usize(0); i < n; i += 4096 {
		unsafe {
			b[i] = 1
		}
	}
	r3 := rss()
	C.madvise(p, n, C.MADV_DONTNEED)
	r4 := rss()
	println('madvise: touched=${r3 / 1024} KB after_dontneed=${r4 / 1024} KB')
}
