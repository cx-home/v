// cm_stale_card.v — a concurrent middle's gate skips a store into a page whose
// card an earlier store set outside any cycle (the permanent regime), and the
// termination re-scan reads cards only for permanent spans. An embedder that
// called vgc_set_permanent (cx does, at start-up) has the gate open over the
// permanent spans' address range between cycles: a store into a NON-permanent
// object whose page lies in that range sets the page's card (vgc_wb_store,
// mode 2), and nothing clears it (young regime off). In a later concurrent
// middle the inline gate sees the card set and returns before vgc_wb_store, so
// the span is not dirtied, and the termination re-scan skips it.
//
// Layout: a start-up set kept at both ends of the arena with large garbage
// buffers between, vgc_set_permanent, a promotion cycle (the garbage is swept,
// the permanent range spans it), then each worker's 4,096-slot window is
// allocated (reusing a swept buffer's span, inside the range) and written once
// with no cycle running (its pages' cards set: `cards=` counts the windows
// whose first page reads set). Then T workers move records out of the tail of
// a ballast chain into the window through a gated store (`*s = v`, the mut
// parameter of https://github.com/cx-home/v/issues/83) while a collector forces
// a cycle every MS ms (VGC_CM=1: every cycle after the promotion concurrent).
// AGE_US > 0 sleeps that long between steps, so a moved record is that old (born
// before the cycle that is marking when it moves); BALLAST is each chain's length.
// A record reclaimed while the window names it reads back torn (`bad=`), and a
// -d vgc_cm_verify build counts every object the concurrent mark missed (`missed=`).
// Prints `perm=.. cards=../.. bad=.. missed=..` and exits 1 on bad > 0 or missed > 0.
module main

import os
import time

@[heap]
struct Rec {
mut:
	a   u64
	b   u64
	p   &Rec = unsafe { nil }
	q   &Rec = unsafe { nil }
	sum u64
}

fn mk(i u64, p &Rec) &Rec {
	return &Rec{
		a:   i
		b:   i ^ 0x9e3779b97f4a7c15
		p:   p
		sum: i + (i ^ 0x9e3779b97f4a7c15)
	}
}

@[inline]
fn whole(r &Rec, id u64) bool {
	return r != unsafe { nil } && r.a == id && r.sum == r.a + r.b
}

const lanes = 16

const window = 4096

struct Slot {
mut:
	r   &Rec = unsafe { nil }
	id  u64
	pad [30]u64
}

struct Old {
mut:
	slots   []Slot
	ballast &Rec = unsafe { nil }
	hidden  []u64
}

@[heap]
struct Flag {
mut:
	stop bool
}

// put stores `v` through the mut parameter: C `*s = v` behind vgc_wb_gate(s)
@[noinline]
fn put(mut s Slot, v Slot) {
	s = v
}

fn worker(mut old Old, id u64, steps int, nb int, age_us int) u64 {
	mut bad := u64(0)
	for k in 0 .. nb {
		old.ballast = mk(u64(k), old.ballast)
		if k < lanes {
			if k == 0 {
				old.hidden = []u64{len: lanes}
			}
			old.hidden[k] = u64(voidptr(old.ballast))
		}
	}
	for s in 0 .. steps {
		i := u64(s) + id * 100000000
		for h in 0 .. lanes {
			mut tail := unsafe { &Rec(voidptr(old.hidden[h])) }
			mut treasure := tail.q
			tail.q = unsafe { nil }
			if treasure != unsafe { nil } {
				put(mut old.slots[(s * lanes + h) % window], Slot{ r: treasure, id: treasure.a })
			}
			tail.q = mk(i * lanes + u64(h) + 50000000, unsafe { nil })
		}
		if age_us > 0 {
			time.sleep(age_us * time.microsecond)
		}
		if s % 64 == 63 || (age_us > 0 && s % 8 == 7) {
			for q in 0 .. window {
				if old.slots[q].r != unsafe { nil } && !whole(old.slots[q].r, old.slots[q].id) {
					bad++
				}
			}
		}
	}
	return bad
}

fn collector(f &Flag, ms int) u64 {
	for !f.stop {
		gc_collect()
		time.sleep(ms * time.millisecond)
	}
	return 0
}

@[noinline]
fn startup(n int) []&Rec {
	mut k := []&Rec{cap: n}
	for i in 0 .. n {
		k << mk(u64(i), unsafe { nil })
	}
	return k
}

@[noinline]
fn garbage(n int) int {
	mut g := [][]Slot{}
	for _ in 0 .. n {
		g << []Slot{len: window}
	}
	return g.len
}

fn main() {
	t := if os.getenv('T').int() > 0 { os.getenv('T').int() } else { 4 }
	steps := if os.getenv('STEPS').int() > 0 { os.getenv('STEPS').int() } else { 40000 }
	ms := if os.getenv('MS').int() > 0 { os.getenv('MS').int() } else { 2 }
	perm := os.getenv('NOPERM') == ''
	nb := if os.getenv('BALLAST').int() > 0 { os.getenv('BALLAST').int() } else { 20000 }
	age_us := os.getenv('AGE_US').int()
	// the start-up set at both ends, large garbage between
	k1 := startup(4000)
	ng := garbage(2 * t + 4)
	k2 := startup(4000)
	if perm {
		vgc_set_permanent()
	}
	gc_collect() // the promotion cycle (stop-the-world)
	gc_collect()
	// the windows, after the promotion: a swept garbage buffer's span each
	mut olds := []&Old{}
	for _ in 0 .. t {
		olds << &Old{
			slots: []Slot{len: window}
		}
	}
	// one store into every slot with no cycle running: the gate (the permanent
	// range between cycles) sets each page's card
	for o in olds {
		mut oo := unsafe { o }
		for q in 0 .. window {
			put(mut oo.slots[q], Slot{})
		}
	}
	mut cards := 0
	for o in olds {
		if vgc_card_dirty(unsafe { &o.slots[0] }) {
			cards++
		}
	}
	mut ts := []thread u64{}
	for p in 0 .. t {
		ts << spawn worker(mut olds[p], u64(p + 1), steps, nb, age_us)
	}
	mut flag := &Flag{}
	col := spawn collector(flag, ms)
	mut bad := u64(0)
	for th in ts {
		bad += th.wait()
	}
	flag.stop = true
	col.wait()
	println('perm=${perm} t=${t} steps=${steps} cards=${cards}/${t} keep=${k1.len + k2.len + ng} bad=${bad} missed=${vgc_cm_verify_missed_count()}')
	if bad > 0 || vgc_cm_verify_missed_count() > 0 {
		exit(1)
	}
}
