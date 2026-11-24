// vgc_large_noscan_pace_test.v — a live set that grows by large pointer-free
// buffers, with as much garbage of the same kind beside it, peaks at most
// 1.3x the live set (https://github.com/cx-home/cx-private/issues/2052,
// regex-redux and reverse-complement).
//
// Shape: 64 steps each keep one 2 MB []u8 (a pointer-free buffer: a noscan
// large span, as a cx string of a sequence is) and drop one beside it, so the
// live set grows to 128 MB; then 4 x 64 steps each replace one kept buffer
// with a fresh one (the substitution chain: the new string kept, the last one
// dropped), so 512 MB of garbage streams past a live set that stays 128 MB.
// The buffers are one size, so a freed span is reused whole and the carve
// measures the pacing, not fragmentation. The bar is the process's peak
// resident set (getrusage ru_maxrss, the quantity the Benchmarks Game reads),
// less its high-water before the run, over the marked live set at the end.
// (The arenas' carve, gc_memory_use(), is printed beside it: it also holds the
// pool spans the collector trimmed back to the OS.)
//
// The pacer's goal is marked + marked x GOGC/100 (2x the live set at the
// default): between two cycles a whole live set's worth of dead buffers may
// pile up. cx's regex-redux (the substitution chain: one fresh ~50 MB string
// a step, the last one dropped) peaks 1.6-2x its live set there — 338 MB at
// the official 5 M against Go's 307 (bar 322.7). A large pointer-free object
// costs its mark one bit and its sweep one span, whatever its size, so a
// tighter goal over those bytes adds collections that cost almost nothing.
//
// Run: ./v test bench/parallel-alloc/vgc_large_noscan_pace_test.v
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

const chunk = 2 * 1024 * 1024
const steps = 64
const rounds = 4

// peak resident over the live set at the end
const peak_over_live_bound = 1.3

fn test_a_growing_large_noscan_live_set_peaks_near_it() {
	gc_collect()
	base := gc_memory_use()
	rss0 := peak_rss()
	mut live := [][]u8{cap: steps}
	mut high := base
	mut sink := u64(0)
	for i in 0 .. steps {
		live << []u8{len: chunk, init: u8(i)}
		g := []u8{len: chunk, init: u8(i + 1)}
		sink += g[i % chunk]
		c := gc_memory_use()
		if c > high {
			high = c
		}
	}
	for i in 0 .. rounds * steps {
		live[i % steps] = []u8{len: chunk, init: u8(i)}
		c := gc_memory_use()
		if c > high {
			high = c
		}
	}
	gc_collect()
	marked := gc_heap_usage().total_bytes
	kept := u64(steps) * u64(chunk)
	rss := peak_rss()
	ratio := f64(rss - rss0) / f64(marked)
	println('vgc_large_noscan_pace: kept=${kept} marked=${marked} rss_before=${rss0} rss_peak=${rss} peak_over_live=${ratio:.3f} bound=${peak_over_live_bound} carved_high=${high - base} carved_over_live=${f64(high - base) / f64(marked):.3f} sink=${sink} n=${live.len}')
	assert live.len == steps
	assert marked >= kept, 'the live buffers were not all marked (${marked} < ${kept})'
	assert ratio <= peak_over_live_bound, 'the peak resident set reached ${ratio:.3f}x a growing live set of large pointer-free buffers (bound ${peak_over_live_bound})'
}
