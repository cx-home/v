// vgc_oversized_regrow_test.v — a buffer that regrows past the arena size, a
// little larger each time (a hash table's arrays as it grows, a builder's
// output), peaks near the two buffers a regrow holds at once, not beside
// every one it freed (https://github.com/cx-home/cx-private/issues/2052,
// k-nucleotide).
//
// Shape: 8 regrows of one pointer-free buffer from 66 MB by 12 MB a step (each
// over the 64 MB arena, so an oversized single-object span on free_oversized
// when it dies; each a little larger than the last, so a freed one never
// serves the next); between regrows 48 MB of small garbage streams past, so
// the collector runs and sweeps the dropped buffer into the pool. The copy
// holds the old and the new buffer at once, and a stale stack slot holds the
// one before (the marked set at the end is two buffers: VGC_GCTRACE=1), so a
// regrow holds the three newest. The bar is the process's peak resident set
// (getrusage ru_maxrss), less its high-water before the run, over those three
// (66 + 12 x {6, 7, 8} MB = 474 MB): bound 1.1.
//
// The pool's compensation (RTMEM-1 (2), vgc_pool_compensate) offsets a carve
// by decommitting idle pooled runs, but it skips oversized spans: a dropped
// table stays resident in free_oversized until vgc_pool_trim's age gate
// (2 full cycles) passes, while the next, larger one maps a fresh arena
// beside it (608 MB here: 1.28x). cx's k-nucleotide at 25 M: live set 295 MB at the end, pool
// 214 MB resident, peak 585-736 MB against Go's 537 (bar 563.7).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_oversized_regrow_test.v
module main

#include <sys/resource.h>

struct C.rusage {
	ru_maxrss i64
}

fn C.getrusage(who int, usage &C.rusage) int

// peak resident bytes so far (ru_maxrss is bytes on macOS, KB elsewhere)
fn peak_rss() u64 {
	mut ru := C.rusage{}
	C.getrusage(0, &ru)
	$if macos {
		return u64(ru.ru_maxrss)
	} $else {
		return u64(ru.ru_maxrss) * 1024
	}
}

const mb = 1024 * 1024
const first = 66 * mb
const step = 12 * mb
const regrows = 8
const garbage = 48 * mb
const bit = 64 * 1024

// peak resident over the three newest buffers a regrow holds
const peak_over_held_bound = 1.1

fn test_an_oversized_buffer_regrowing_peaks_near_the_buffers_it_holds() {
	gc_collect()
	rss0 := peak_rss()
	mut buf := []u8{len: first, init: 1}
	mut sink := u64(0)
	for r in 1 .. regrows + 1 {
		mut next := []u8{len: first + r * step}
		copy(mut next, buf)
		unsafe {
			buf = next
		}
		for i in 0 .. garbage / bit {
			g := []u8{len: bit, init: u8(i)}
			sink += g[r]
		}
	}
	gc_collect()
	marked := gc_heap_usage().total_bytes
	last := u64(first + regrows * step)
	rss := peak_rss()
	held := 3 * last - 3 * u64(step)
	ratio := f64(rss - rss0) / f64(held)
	println('vgc_oversized_regrow: last=${last} held=${held} marked=${marked} rss_before=${rss0} rss_peak=${rss} peak_over_held=${ratio:.3f} bound=${peak_over_held_bound} peak_over_last=${f64(rss - rss0) / f64(last):.3f} sink=${sink} b0=${buf[0]}')
	assert marked >= last, 'the live buffer was not marked (${marked} < ${last})'
	assert ratio <= peak_over_held_bound, 'the peak resident set reached ${ratio:.3f}x the three newest buffers of a regrowing oversized buffer (bound ${peak_over_held_bound}): dropped ones stayed resident beside the next'
}
