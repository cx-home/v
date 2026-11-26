// ptr_index.v — the program vgc_young_ptr_index_test.v builds (https://github.com/cx-home/v/issues/93).
// A store through a raw pointer index, `unsafe { p[i] = v }` with p a `&T` into an
// array's buffer, is how cx's interpreter appends to a node array in place
// (cx-core-code compiled_def.v node_push) and fills a run's argument slots
// (crun_args_in). Each round allocates the buffers, churns so a minor cycle marks
// them (sticky: old from then on), then stores fresh (young) objects into them
// through the raw pointer only, churns again (more minors) and checks every
// value. A store the barrier does not see leaves no card on the old buffer, the
// minors trace nobody to the young objects and sweep them while the buffer still
// names them. bad = slots whose object changed.
import os

struct Box {
	v   i64
	pad [6]u64
}

// a value with a pointer in it, as cx.Node is (a tag and a reference)
struct Cell {
	tag int
	box &Box = unsafe { nil }
}

struct Node {
	next &Node = unsafe { nil }
	pad  [6]u64
}

fn churn(mb int) int {
	mut s := 0
	for _ in 0 .. mb * 1024 {
		b := []u8{len: 1000, init: u8(s)}
		s += b[999]
		// the size of a Box, filled: a swept one handed out again reads changed
		w := []i64{len: 8, init: 0x7777}
		s += int(w[7] & 1)
		mut chain := &Node(unsafe { nil })
		for _ in 0 .. 4 {
			chain = &Node{
				next: chain
			}
		}
		s += int(chain.pad[0])
	}
	return s
}

fn want(round int, i int) i64 {
	return i64(round) * 100_000 + i64(i) * 7 + 1
}

@[noinline]
fn fill_ptrs(mut a []&Box, round int) {
	unsafe {
		mut p := &&Box(a.data)
		for i in 0 .. a.len {
			p[i] = &Box{
				v: want(round, i)
			}
		}
	}
}

@[noinline]
fn fill_cells(mut a []Cell, round int) {
	unsafe {
		mut p := &Cell(a.data)
		for i in 0 .. a.len {
			p[i] = Cell{
				tag: i
				box: &Box{
					v: want(round, i)
				}
			}
		}
	}
}

fn check_ptrs(a []&Box, round int) int {
	mut bad := 0
	for i, b in a {
		if b == unsafe { nil } || b.v != want(round, i) || b.pad[0] != 0 {
			bad++
		}
	}
	return bad
}

fn check_cells(a []Cell, round int) int {
	mut bad := 0
	for i, c in a {
		if c.tag != i || c.box == unsafe { nil } || c.box.v != want(round, i) || c.box.pad[0] != 0 {
			bad++
		}
	}
	return bad
}

fn main() {
	rounds := os.getenv_opt('ROUNDS') or { '20' }.int()
	n := 2000
	mut bad := 0
	for round in 0 .. rounds {
		mut ptrs := []&Box{len: n}
		mut cells := []Cell{len: n}
		// minors while the buffers are live: they are old from here on
		_ := churn(2)
		fill_ptrs(mut ptrs, round)
		fill_cells(mut cells, round)
		_ := churn(4)
		bad += check_ptrs(ptrs, round) + check_cells(cells, round)
	}
	println('done bad=${bad} rounds=${rounds} minors=${vgc_minor_cycles_count()}')
}
