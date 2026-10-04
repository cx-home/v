// Refutation: a buffered channel's statusbuf is vcalloc_noscan(cap * 2); for
// cap 1..7 that is a tiny-packed request, and when the current tiny block was
// opened by an uninit noscan allocation the status words are stale, not
// BufferElemStat.unused — the writer spins on CAS(unused -> writing) forever.
module main

import time

@[noinline]
fn dirty_slots() {
	mut keep := []voidptr{cap: 20000}
	for _ in 0 .. 20000 {
		p := unsafe { malloc_noscan(16) }
		unsafe { C.memset(p, 0xAB, 16) }
		keep << voidptr(p)
	}
	keep.clear()
}

struct Done {
mut:
	n int
}

fn writer(chs []chan int, mut d Done) {
	for ch in chs {
		ch <- 1
		_ := <-ch
		d.n++
	}
}

fn test_small_buffered_channel_status_is_unused() {
	dirty_slots()
	for _ in 0 .. 3 {
		gc_collect()
	}
	mut chs := []chan int{}
	mut keep := [][]u8{}
	for _ in 0 .. 3000 {
		x := []u8{} // opens a tiny block uninit
		keep << x
		chs << chan int{cap: 1} // statusbuf = vcalloc_noscan(2), packed after it
	}
	mut d := &Done{}
	spawn writer(chs, mut d)
	time.sleep(1500 * time.millisecond)
	println('TINYCHAN completed ${d.n} of ${chs.len} buffered cap-1 channel round trips in 1.5 s')
	if d.n != chs.len {
		println('TINYCHAN RED: writer hung on a stale status word')
		exit(1)
	}
}
