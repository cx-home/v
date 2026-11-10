// vgc_free_page_census_test.v — what a page return inside in-use spans could
// give back (cx-platform-store#58, RULING 189). vgc_free_page_census answers the
// bytes of vgc pages (8 KB) no allocated object touches inside in-use spans,
// and of those the ones whose whole 16 KB OS page holds no live vgc page.
//
// Shape: many objects of a multi-page class (2,304 B — 3 pages a span) of which
// one in 64 stays alive: after a collection most pages inside the kept spans
// are free and most pairs of them are whole OS pages; with every object kept,
// none are.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_free_page_census_test.v
module main

struct Blob {
	b [2200]u8
}

@[noinline]
fn fill(n int, keep_every int) []&Blob {
	mut kept := []&Blob{}
	for i in 0 .. n {
		p := &Blob{}
		if i % keep_every == 0 {
			kept << p
		}
	}
	return kept
}

fn test_free_pages_inside_in_use_spans_are_counted() {
	kept := fill(40000, 64)
	gc_collect()
	gc_collect()
	free8, free16, _ := vgc_free_page_census()
	assert kept.len == 625
	// a 2,304-byte class span is two vgc pages holding three objects, all in
	// its first page: a span kept alive by one object has its second page free
	assert free8 >= 8192, 'free pages inside in-use spans: ${free8}'
	assert free16 <= free8 && free8 % 8192 == 0, '${free8} / ${free16}'
}
