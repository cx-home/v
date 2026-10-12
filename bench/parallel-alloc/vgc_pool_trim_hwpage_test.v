// vgc_pool_trim_hwpage_test.v — cx-private#1886: the pool trim returns the
// pages of one-page pooled spans on a host whose hardware page is larger than
// a vgc page (16 KB on Apple Silicon), where a pooled neighbour shares the
// hardware page.
//
// Spans under vgc_pool_merge_min pages are pooled alone (never coalesced), and
// vgc_os_decommit returns only the hardware-aligned inner range of what it is
// given, so on a 16 KB-page host the trim of each lone 8 KB span returned
// nothing while it flagged the span cold and counted it in trimmed=: pi-digits
// 3000 read trimmed=7.7 MB with 10.5 MB of its arena resident for a 2.5 MB
// in-use + 2.3 MB hot pool. The trim now widens a decommit to the whole
// hardware page when the vgc pages it would share it with are pooled too.
//   - ~1,000 one-page spans of 208 B objects, dropped together, are out of
//     core after the collections that age and trim them (RED on 73bbc6398c on
//     a 16 KB-page host: every page stayed resident). A 4 KB-page host
//     returned them before as well; the bar is the same there.
//   - a span that stays live keeps its contents across the trims of its
//     pooled neighbours (the collateral-corruption guard of cx #360).
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_pool_trim_hwpage_test.v
module main

#include <sys/mman.h>
#include <unistd.h>

fn C.mincore(addr voidptr, len usize, vec &char) int
fn C.getpagesize() int

const mask = usize(0x5a5a_5a5a_5a5a_5a5a)
const nobj = 40000
const osz = 200

struct Bounds {
	lo usize
	hi usize
}

@[noinline]
fn scrub_stack() u64 {
	mut buf := [8192]u64{}
	for i in 0 .. buf.len {
		buf[i] = u64(i) ^ 0x3c3c
	}
	return buf[8191]
}

// fill allocates nobj objects of one size class and returns their address
// range masked, so no word on the stack or in the data segment still reads
// as a pointer into them once they are dropped.
@[noinline]
fn fill() Bounds {
	mut keep := [][]u8{cap: nobj}
	mut lo := usize(max_u64)
	mut hi := usize(0)
	for i in 0 .. nobj {
		a := []u8{len: osz, init: u8(i)}
		p := usize(a.data)
		if p < lo {
			lo = p
		}
		if p + osz > hi {
			hi = p + osz
		}
		keep << a
	}
	return Bounds{lo ^ mask, hi ^ mask}
}

fn resident_pages(b Bounds) (int, int) {
	pg := usize(C.getpagesize())
	lo := (b.lo ^ mask) & ~(pg - 1)
	hi := ((b.hi ^ mask) + pg - 1) & ~(pg - 1)
	n := int((hi - lo) / pg)
	mut vec := []u8{len: n}
	if C.mincore(voidptr(lo), hi - lo, &char(vec.data)) != 0 {
		return -1, n
	}
	mut r := 0
	for v in vec {
		if v & 1 != 0 {
			r++
		}
	}
	return r, n
}

fn test_dropped_one_page_spans_leave_core() {
	$if windows {
		return
	}
	b := fill()
	_ := scrub_stack()
	before, n := resident_pages(b)
	assert before >= 0
	for _ in 0 .. 24 {
		gc_collect()
	}
	after, _ := resident_pages(b)
	println('range ${n} hardware pages: resident ${before} after the fill, ${after} after the trims')
	assert after * 4 <= n, 'the trims left ${after} of ${n} hardware pages of the dropped one-page spans resident'
}

@[heap]
struct Keeper {
mut:
	cells [][]u8
}

fn test_live_spans_keep_their_contents_across_neighbour_trims() {
	mut k := &Keeper{}
	mut drop := [][]u8{}
	// interleave survivors and garbage of one size class, so live and pooled
	// one-page spans sit side by side
	for i in 0 .. nobj {
		a := []u8{len: osz, init: u8(i % 251)}
		if (i / 40) % 2 == 0 {
			k.cells << a
		} else {
			drop << a
		}
	}
	drop = [][]u8{}
	_ := scrub_stack()
	for _ in 0 .. 24 {
		gc_collect()
	}
	mut idx := 0
	for i in 0 .. nobj {
		if (i / 40) % 2 == 0 {
			c := k.cells[idx]
			assert c.len == osz
			for j in 0 .. osz {
				assert c[j] == u8(i % 251), 'live cell ${idx} byte ${j} reads ${c[j]} after its neighbours were trimmed'
			}
			idx++
		}
	}
}
