// vgc_first_trigger_test.v — a program's start-up allocates its first few MB
// before the collector's first cycle (cx-private#1934).
//
// The first collection triggered at the one-thread floor (vgc_headroom_floor_lo1,
// 256 KB): a native n-body binary ran three collections before its first step,
// ~0.8 ms of its 6.3 ms start on dev2. The first trigger is now its own value,
// vgc_first_trigger (VGC_FIRST_TRIGGER_KB overrides), and the pacing after the
// first cycle keeps the 256 KB floor, so a small live set still paces as tight as
// before. The spec: 2 MB of live allocation from a fresh process runs no cycle;
// 64 MB of churn still collects (the first trigger is a start-up allowance, not a
// ceiling).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_first_trigger_test.v
module main

@[heap]
struct Cell {
mut:
	next &Cell = unsafe { nil }
	pad  [6]u64
}

@[noinline]
fn build(n int) &Cell {
	mut head := &Cell(unsafe { nil })
	for i in 0 .. n {
		mut c := &Cell{
			next: head
		}
		c.pad[0] = u64(i)
		head = c
	}
	return head
}

@[noinline]
fn count(h &Cell) int {
	mut n := 0
	mut c := unsafe { h }
	for c != unsafe { nil } {
		n++
		c = c.next
	}
	return n
}

fn test_start_up_allocates_two_mb_before_the_first_cycle() {
	c0 := gc_cycles()
	// 64-byte cells: ~32,000 of them is 2 MB live
	h := build(32_000)
	c1 := gc_cycles()
	assert count(h) == 32_000
	assert c1 == c0, '${c1 - c0} collection(s) ran in the first 2 MB of start-up (first trigger too low)'
}

fn test_churn_past_the_first_trigger_still_collects() {
	c0 := gc_cycles()
	mut kept := 0
	for _ in 0 .. 64 {
		h := build(16_000) // ~1 MB each, dropped
		kept += count(h)
	}
	assert kept == 64 * 16_000
	assert gc_cycles() > c0, 'no collection over 64 MB of churn'
}
