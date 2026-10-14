// vgc_data_const_test.v — __DATA_CONST is not a root range (cx-home/v#15).
//
// The conservative data-segment scan walked the main image's __DATA_CONST on
// every cycle: ~208 KB in cx (its GOT and const tables of addresses into
// __TEXT/__DATA), and the image sits inside the span lookup's address range, so
// every word paid a span lookup. On pi-digits 3000 that was 37 of the 85 us
// data phase and of a 142 us cycle (103 us without it). dyld writes those
// pointers during the image's fixups and maps the segment read-only before any
// initializer runs, so no store made once the arenas exist can leave a heap
// address there: it is not a root.
//   - no cached root range overlaps the main image's __DATA_CONST (darwin;
//     elsewhere there is no such segment and the case reads nothing);
//   - the premise: __DATA_CONST is read-only while the program runs. If a
//     future loader leaves it writable, this case fails and the range must be
//     scanned again.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_data_const_test.v
module main

#include "@DIR/vgc_data_const.h"

fn C.vgc_dc_bound(hi int) usize
fn C.vgc_dc_writable() int

fn test_no_root_range_covers_data_const() {
	lo := C.vgc_dc_bound(0)
	hi := C.vgc_dc_bound(1)
	if lo == 0 || hi <= lo {
		return
	}
	gc_collect() // the ranges are cached at vgc_init; a cycle reads them
	assert vgc_nseg > 0, 'no data-segment root range was cached'
	for k in 0 .. vgc_nseg {
		overlap := vgc_seg_lo[k] < hi && vgc_seg_hi[k] > lo
		assert !overlap, 'root range ${k} [0x${vgc_seg_lo[k]:x}, 0x${vgc_seg_hi[k]:x}) overlaps __DATA_CONST [0x${lo:x}, 0x${hi:x})'
	}
}

fn test_data_const_is_read_only_while_the_program_runs() {
	w := C.vgc_dc_writable()
	if w < 0 {
		return
	}
	assert w == 0, '__DATA_CONST is writable at run time: a store could leave a heap address there, so it must be scanned'
}
