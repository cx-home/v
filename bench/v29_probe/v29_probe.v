// cx-home/v#29 diagnostic: vgc_refute_tiny_gate's 4 KB child stream as a program
// (run under VGC_GCTRACE=1 for the gate / refusal lines).
module main

const chunk = 4096
const live_bytes = 192 * 1024 * 1024

fn main() {
	mut live := [][]u8{cap: live_bytes / chunk}
	for _ in 0 .. live_bytes / chunk {
		live << []u8{len: chunk, init: 7}
	}
	gc_collect()
	gc_collect()
	marked := gc_heap_usage().total_bytes
	mut high := gc_memory_use()
	mut sink := u64(0)
	for i in 0 .. 4 * live_bytes / chunk {
		t := []u8{len: chunk, init: u8(i)}
		sink += t[i % chunk]
		if i % 256 == 0 {
			c := gc_memory_use()
			if c > high {
				high = c
			}
		}
	}
	println('CHILD-RATIO=${f64(high) / f64(marked):.3f} sink=${sink} kept=${live.len}')
}
