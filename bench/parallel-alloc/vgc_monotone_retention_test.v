// vgc_monotone_retention_test.v — a monotone build-up through interleaved
// transients must peak at no more than 2.5× the live set it builds
// (cx-home/v#6, cx-private RTMEM-1; the bar is cx-private's 1226-a,
// "RSS ÷ live ≤ 2.5× at parse peak").
//
// The shape is a parse followed by an emit, the workload the bar was measured
// on: records are built one at a time into a growing array, each through
// short-lived token strings and split arrays that die at once, and then the
// whole set is serialised into one growing output buffer through per-record
// lines that die at once. The live set only grows; each cycle's garbage is
// transients. vgc's pacer lets the heap reach marked × (1 + GOGC/100) — 2× the
// live set at the default — before it collects, so 2× is the floor of this
// ratio and the 0.5 above it is what retention, fragmentation and the
// collector's own footprint may cost together.
//
// Before RTMEM-1 three things sat above that floor (vgc_d_vgc.c.v's RTMEM-1
// block): every span acquired during an epoch skipped the sweep that ended
// it, so each epoch's transients survived one extra cycle; a large request
// (the record array's and the output buffer's next capacity) that no pooled
// span covered carved fresh arena pages beside committed, idle runs of the
// small spans the transients had emptied; and every mark work buffer was a
// whole hardware page. Measured on dev2 (darwin arm64, 16 KB pages): 3.16×
// on the pinned fork 77a460e26, 2.30× after.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_monotone_retention_test.v
// Requires -gc e: `gc_heap_usage().total_bytes` after `gc_collect()` is the
// bytes vgc marked. Everything the build-up made — the records and the output
// buffer itself, not a copy — is held across that reading, so the denominator
// is the whole live set and no transient of the run.
module main

import strings
import runtime

#include <sys/resource.h>

struct C.rusage {
	ru_maxrss i64
}

fn C.getrusage(who int, usage &C.rusage) int

const record_count = 500_000
const parse_rounds = 8 // transient token rounds per record
const emit_rounds = 2 // transient line copies per record

// The bound under test (1226-a). Not a tuning knob: a regression reds here.
const peak_over_live_bound = 2.5

struct Rec {
	id    int
	name  string
	tags  []string
	score f64
}

fn peak_rss_bytes() u64 {
	mut ru := C.rusage{}
	C.getrusage(0, &ru) // RUSAGE_SELF
	$if macos {
		return u64(ru.ru_maxrss) // darwin reports bytes
	} $else {
		return u64(ru.ru_maxrss) * 1024 // linux and the BSDs report KiB
	}
}

// build is the parse: one record per step, each through transients that die
// before the next step.
fn build() []&Rec {
	mut recs := []&Rec{}
	for i in 0 .. record_count {
		tok := 'record-${i}-field-${i * 7}-tail'
		mut parts := tok.split('-')
		for j in 0 .. parse_rounds {
			t := '${tok}/${j}/${parts[j % parts.len]}'
			ps := t.split('/')
			parts[j % 2] = ps[2]
		}
		recs << &Rec{
			id:    i
			name:  parts[1] + ':' + parts[3]
			tags:  [parts[0].clone(), parts[4].clone()]
			score: f64(i) / 3.0
		}
	}
	return recs
}

// emit is the convert's second half: per-record transient lines into one
// growing output buffer, which the caller keeps.
fn emit(recs []&Rec) strings.Builder {
	mut sb := strings.new_builder(64)
	for r in recs {
		mut line := '{"id":${r.id},"name":"${r.name}","tags":["${r.tags[0]}","${r.tags[1]}"],"score":${r.score}}'
		for _ in 0 .. emit_rounds {
			line = line.replace('"', '"') + ''
		}
		sb.write_string(line)
		sb.write_u8(`\n`)
	}
	return sb
}

fn test_a_monotone_build_up_peaks_within_two_and_a_half_times_its_live_set() {
	recs := build()
	out := emit(recs)
	peak := peak_rss_bytes()
	gc_collect()
	live := gc_heap_usage().total_bytes
	ratio := f64(peak) / f64(live)
	println('vgc_monotone_retention: records=${recs.len} out_bytes=${out.len} peak_rss=${peak} live=${live} peak_over_live=${ratio:.3f} bound=${peak_over_live_bound}')
	// the live set is held whole across the reading
	assert recs.len == record_count
	assert out.len > 0
	assert live > 128 * 1024 * 1024, 'the live set must dwarf the adaptive headroom (64 MB) for the GOGC term to pace'
	assert ratio <= peak_over_live_bound, 'peak RSS ${peak} B is ${ratio:.3f}× the ${live} B live set (bound ${peak_over_live_bound}×)'
}

// ── refutation cases (RTMEM-1's adversarial read) ──────────────────────────

// fill_and_drop allocates one large transient, touches every page, and drops
// it: the caller holds no reference once it returns.
@[noinline]
fn fill_and_drop(n int) int {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = 1
	}
	return b.len
}

// A large transient a thread drops must be reclaimed by the collections after
// it, whatever that thread allocates next. The acquisition stamp protects a
// span for the one sweep after it is handed out; an in-flight slot that held
// the thread's LAST large span until its NEXT large allocation kept a dropped
// 60 MB buffer unswept for the rest of a small-only build-up (the read:
// 2.40× → 2.79× peak over live). Two explicit collections return the pool to
// the OS, so the buffer's pages leave RSS if and only if it was swept.
fn test_a_dropped_large_buffer_is_reclaimed_by_the_next_collections() {
	n := 60 * 1024 * 1024
	assert fill_and_drop(n) == n
	held := runtime.used_memory() or { 0 }
	gc_collect()
	gc_collect()
	after := runtime.used_memory() or { 0 }
	println('vgc_monotone_retention: dropped_large held_rss=${held} after_two_collections=${after}')
	assert held > 0
	assert after + u64(n / 2) < held, 'a dropped ${n} B buffer stayed resident across two collections: rss ${held} -> ${after}'
}

// A large carve's compensation walk costs the heap once per cycle, not once
// per carve: a build-up of retained 17-page buffers among small garbage carves
// on every buffer, and a walk that restarted at page 0 each time measured
// 1.3–2.3× the wall time of the pinned collector (most samples inside
// vgc_pool_compensate_arena, under free_spans_lock; this shape walked 14.6
// heaps per cycle).
fn test_large_carves_walk_the_page_maps_once_per_cycle() {
	s0, c0, _ := vgc_rtmem_compensation_stats()
	mut keep := [][]u8{}
	mut sink := 0
	for i in 0 .. 4000 {
		mut b := []u8{len: 136 * 1024}
		b[0] = u8(i)
		keep << b
		for g in 0 .. 1000 {
			t := 'garbage-${i}-${g}'
			sink += t.len
		}
	}
	s1, c1, pages := vgc_rtmem_compensation_stats()
	scanned := s1 - s0
	cycles := c1 - c0
	bound := 2 * (cycles + 1) * pages
	println('vgc_monotone_retention: compensation scanned=${scanned} cycles=${cycles} heap_pages=${pages} bound=${bound} sink=${sink}')
	assert keep.len == 4000
	assert scanned <= bound, 'compensation walked ${scanned} page-map slots over ${cycles} cycles of a ${pages}-page heap (bound ${bound}: twice the heap per cycle)'
}
