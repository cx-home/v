// vgc_cold_class_main_test.v — a program's first thread takes no shared span
// per cold class (cx-home/cx-core-code#295 from the V side; the v#77 cold-class
// carve, piece (a)).
//
// Shape: the main thread alone allocates three objects in each of twenty size
// classes (16 B .. 2 KB) and keeps them live. Under the v#77 cold-class carve a
// thread's first two objects of a class came from the class's shared span and
// the third from a private span, so a thread that warms every class it touches
// paid two spans per class: the shared one and its own. For a short program
// that is one more 16 KB page resident per class it touches: `cx --version`
// read 6,000 KB before the carve and 6,400 KB with it (25 classes; the bound is
// 6,400). The cold carve exists for threads started together (the
// vgc_cold_class_pack_test case); the main thread runs first and alone, so it
// starts warm and carves only its own spans.
//
// The bar: the carve over the three objects per class stays under one span per
// class (8 KB) plus a quarter; the shared-span carve read about two spans per
// class.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_cold_class_main_test.v
module main

const sizes = [16, 24, 32, 48, 64, 80, 96, 128, 160, 192, 256, 320, 384, 512, 640, 768, 1024,
	1280, 1536, 2048]

fn test_main_thread_takes_one_span_per_class() {
	gc_collect()
	before := gc_memory_use()
	mut keep := [][]u8{cap: 3 * sizes.len}
	for sz in sizes {
		for k in 0 .. 3 {
			keep << []u8{len: sz, init: u8(sz + k)}
		}
	}
	gc_collect()
	after := gc_memory_use()
	mut live := 0
	for b in keep {
		live += b.len
	}
	carved := i64(after) - i64(before)
	per_class := carved / i64(sizes.len)
	eprintln('main thread classes=${sizes.len} live=${live} B carved=${carved} B (${carved / 1024} KB, ${per_class} B a class)')
	assert per_class <= 8192 + 2048, 'the main thread carved ${per_class} B a class for three objects each (a shared span and a private one per class)'
}
