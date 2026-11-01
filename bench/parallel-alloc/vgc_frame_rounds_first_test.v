// vgc_frame_rounds_first_test.v — a frame request (a quarter arena or more,
// vgc_frame_pages) is rounded up to a sixteenth of the power of two at or
// below it from its FIRST request (vgc_large_round, cx-home/v#58), not only
// once another size of its granule block was seen: a batch writer's frame
// drifts a few pages every period, so its first period's span, carved exact,
// came 50–191 pages short of the second period's rounded request and every
// frame carved twice — 4,814 then 4,864 pages, 5,953 then 6,144
// (measure/collector-epic-76, the carve lines at G-1's cycles 112, 113, 137
// and 139). A request under the quarter still rounds only on the drift
// signal (a buffer doubled through each size once stays exact).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_frame_rounds_first_test.v
module main

const page = 8192 // vgc's page

@[noinline]
fn fill(n int) []u8 {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = u8(i)
	}
	return b
}

fn test_a_frame_rounds_from_its_first_request_and_a_buffer_does_not() {
	frame := fill(4760 * page) // 4761 pages with the header: the block (4608, 4864]
	fp, _, _ := vgc_span_probe(frame.data)
	assert vgc_large_round_probe(4761) == 4864
	assert fp == 4864, 'the first request of a frame size is not its rounded size: ${fp} pages, not 4864'
	buf := fill(1000 * page) // 1001 pages, under the quarter: exact until its block drifts
	bp, _, _ := vgc_span_probe(buf.data)
	assert bp == 1001, 'a first request under the quarter is rounded: ${bp} pages, not 1001'
	println('vgc_frame_rounds_first: a 4761-page frame request took a ${fp}-page span, a 1001-page buffer a ${bp}-page one (${frame.len} ${buf.len})')
}
