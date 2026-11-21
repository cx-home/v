// planted.v — the program vgc_unaligned_audit_test.v builds with
// -d vgc_unaligned_audit (cx-home/v#74, option (c)). MODE=real plants a 64 KB
// buffer's only reference at an unaligned stack offset, collects, then reads
// the reference back into an aligned local and collects again: the audit must
// count one unaligned-only root and call it real (the object came back to an
// aligned word while still the same allocation). MODE=false plants the same
// word and never reads it back: one unaligned-only root, none real. Prints
// `ua only=<n> real=<n> cycles=<n>` after the collections.
module main

import os

const buf_len = 64 * 1024

@[noinline]
fn hide(mut slot [16]u8, off int) {
	b := []u8{len: buf_len, init: 7}
	p := u64(voidptr(b.data))
	unsafe { C.memcpy(&slot[off], &p, 8) }
}

@[noinline]
fn hide_under_guard(mut slot [16]u8, off int) u64 {
	mut guard := [32]u64{}
	hide(mut slot, off)
	return guard[31]
}

@[noinline]
fn read_back(slot [16]u8, off int) &u8 {
	mut p := u64(0)
	unsafe { C.memcpy(&p, &slot[off], 8) }
	return unsafe { &u8(voidptr(p)) }
}

// read_word answers the planted word as an integer (MODE=stale: an aligned
// word that names the buffer and is never used as a reference)
@[noinline]
fn read_word(slot [16]u8, off int) u64 {
	mut p := u64(0)
	unsafe { C.memcpy(&p, &slot[off], 8) }
	return p
}

@[noinline]
fn sum7(p &u8) int {
	mut n := 0
	for i in 0 .. buf_len {
		if unsafe { p[i] } == 7 {
			n++
		}
	}
	return n
}

// hide_small plants a 200-byte buffer's only reference at an unaligned offset
@[noinline]
fn hide_small(mut slot [16]u8, off int) {
	b := []u8{len: 200, init: 5}
	p := u64(voidptr(b.data))
	unsafe { C.memcpy(&slot[off], &p, 8) }
}

// free_and_reuse frees the planted buffer (the program's own eager free, as
// V's -autofree / cx's Perceus frees do) and allocates 200-byte buffers until
// one lands at its address; answers that buffer (MODE=freed)
@[noinline]
fn free_and_reuse(slot [16]u8, off int, mut keep [][]u8) []u8 {
	mut p := u64(0)
	unsafe { C.memcpy(&p, &slot[off], 8) }
	unsafe { free(voidptr(p)) }
	for _ in 0 .. 100000 {
		b := []u8{len: 200, init: 9}
		if u64(voidptr(b.data)) == p {
			return b
		}
		keep << b
	}
	return []u8{}
}

// scrub overwrites the dead stack below the caller (hide's frame and its
// callees' leave the buffer's address in aligned slots)
@[noinline]
fn scrub() u64 {
	mut z := [2048]u64{}
	z[2047] = 1
	return z[0] + z[2047]
}

// worker_holds plants the buffer's only reference at an unaligned offset of its
// own frame on a spawned thread and blocks until main has collected (MODE=thread)
@[noinline]
fn worker_holds(off int, ready chan int, done chan int) {
	mut wslot := [16]u8{}
	_ = hide_under_guard(mut wslot, off)
	_ = scrub()
	ready <- 1
	_ := <-done
	_ = wslot[0]
}

fn main() {
	mode := os.getenv_opt('MODE') or { 'real' }
	if mode == 'thread' {
		woff := (os.getenv_opt('OFF') or { '3' }).int()
		ready := chan int{cap: 1}
		done := chan int{cap: 1}
		t := spawn worker_holds(woff, ready, done)
		_ := <-ready
		gc_collect()
		done <- 1
		t.wait()
		_, dl := vgc_unaligned_audit_poisoned()
		println('ua thread done dl=${dl}')
		return
	}
	off := (os.getenv_opt('OFF') or { '3' }).int()
	gc_collect()
	o0, r0, _ := vgc_unaligned_audit_counts()
	mut slot := [16]u8{}
	_ = hide_under_guard(mut slot, off)
	gc_collect()
	mut sevens := -1
	if mode == 'real' {
		held := read_back(slot, off)
		slot = [16]u8{}
		if os.getenv('VGC_UA_POISON') == '1' {
			// the program that really holds the buffer writes to it
			unsafe {
				held[100] = 1
			}
		}
		gc_collect()
		sevens = sum7(held)
	} else if mode == 'freed' {
		mut s2 := [16]u8{}
		hide_small(mut s2, off)
		_ = scrub()
		gc_collect()
		mut keep := [][]u8{}
		reused := free_and_reuse(s2, off, mut keep)
		s2 = [16]u8{}
		_ = scrub()
		gc_collect()
		sevens = if reused.len == 200 { 1 } else { 0 }
		keep.clear()
	} else if mode == 'stale' {
		// the word's VALUE sits in an aligned local across the next collections
		// and is never used as a reference: a stale word in a frame's unwritten
		// slot, or an integer that happens to name the dropped buffer
		junk := read_word(slot, off)
		gc_collect()
		gc_collect()
		sevens = int(junk & 1)
	} else {
		gc_collect()
		gc_collect()
	}
	o1, r1, c1 := vgc_unaligned_audit_counts()
	pz, dl := vgc_unaligned_audit_poisoned()
	println('ua only=${o1 - o0} real=${r1 - r0} cycles=${c1} sevens=${sevens} slot=${slot[0]} poison=${pz} dl=${dl}')
}
