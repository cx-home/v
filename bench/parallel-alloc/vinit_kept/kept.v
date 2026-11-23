// kept.v — builtin's first objects stay in the collector's books
// (vgc_heap_vinit_kept_test.v).
//
// builtin's consts are the first statements of _vinit: `error_sentinel` boxes a
// MessageError on the heap before any of the collector's own globals' statements
// run. Those statements used to assign the globals again in _vinit — the heap
// record zeroed by memset, the arena range set back to 0 — so the spans and the
// arena builtin's consts had carved fell out of the collector's books while
// their pages stayed mapped. main asks the collector where that first object
// lives: the arena that holds it and the span that owns it, and whether the
// arenas' carved bytes count its page.
//
//   ./v -gc e run kept.v     prints `arena=<i> span=<yes|no> carved=<n>`
module main

fn main() {
	// an interface value is its object pointer, then its type index
	err := error_sentinel
	p := unsafe { *(&voidptr(&err)) }
	arena, _ := vgc_arena_probe(p)
	span := vgc_find_span_addr(p) != 0
	println('arena=${arena} span=${if span { 'yes' } else { 'no' }} carved=${vgc_carved_probe()}')
}
