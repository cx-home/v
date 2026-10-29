// minor_perm.v — the minor cycle over the permanent generation's spans
// (cx-home/v#56 step 2, `-gc e`; the cycle's doc at vgc_young_minors in
// vlib/builtin/vgc_d_vgc.c.v). CELLS cells of one size class are allocated and
// every other one dropped; the kept ones are made permanent (vgc_set_permanent
// + gc_collect: their spans are permanent, with the dropped cells' slots free).
// Then CELLS new cells are allocated — they take the free slots of those spans
// (same_span= counts the new cells whose span is a kept cell's) — and a full
// cycle (gc_collect) makes them old: old objects outside the generation, in
// permanent spans. Then STEPS rounds, each allocating 256 records it drops (the
// young garbage the pacer's cycles reclaim) and one young record it stores into
// a new cell (cell.p = r: the record's only reference, found at a minor cycle
// through the card of the cell's page). At the end every cell is read back:
// bad=0 when every record reads as stored. Prints done steps= bad= same_span=
// minors= (vgc_minor_cycles_count) and missed= (-d vgc_cm_verify's count, 0
// under other builds).
module main

import os

@[heap]
struct Rec {
mut:
	v   u64
	pad [5]u64
}

@[heap]
struct Cell {
mut:
	p   &Rec = unsafe { nil }
	pad [5]u64
}

fn mk(v u64) &Rec {
	return &Rec{
		v: v
	}
}

fn mk_cell() &Cell {
	return &Cell{}
}

fn main() {
	steps := os.getenv_opt('STEPS') or { '4000' }.int()
	ncells := 2048
	mut kept := []&Cell{len: ncells, init: unsafe { nil }}
	for i in 0 .. 2 * ncells {
		c := mk_cell()
		if i % 2 == 0 {
			kept[i / 2] = c
		}
	}
	vgc_set_permanent()
	gc_collect() // the promotion: the kept cells are permanent, the dropped slots free
	mut spans := map[u64]bool{}
	for i in 0 .. ncells {
		spans[u64(vgc_find_span_addr(kept[i]))] = true
	}
	mut cells := []&Cell{len: ncells, init: unsafe { nil }}
	mut same := 0
	for i in 0 .. ncells {
		cells[i] = mk_cell()
		if u64(vgc_find_span_addr(cells[i])) in spans {
			same++
		}
	}
	gc_collect() // a full cycle: the new cells are old
	mut expect := u64(0)
	mut g := &Rec(unsafe { nil })
	for s in 0 .. steps {
		for j in 0 .. 256 {
			g = mk(u64(j))
		}
		k := s % ncells
		y := mk(u64(s) * 7 + 1)
		if cells[k].p != unsafe { nil } {
			expect -= cells[k].p.v
		}
		cells[k].p = y
		expect += y.v
	}
	mut sum := u64(0)
	for k in 0 .. ncells {
		if cells[k].p != unsafe { nil } {
			sum += cells[k].p.v
		}
	}
	bad := if sum == expect { 0 } else { 1 }
	println('done steps=${steps} bad=${bad} same_span=${same} last=${g.v} kept=${kept.len} minors=${vgc_minor_cycles_count()} missed=${vgc_cm_verify_missed_count()}')
}
