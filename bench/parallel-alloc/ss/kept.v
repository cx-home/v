// kept.v — the program vgc_shadow_stack_cost_test.v builds -prod (cx-home/v#74
// piece 5). spin holds a string parameter and a string local across calls the
// compiler cannot see through (C.getpid) and reads their lengths after each
// call. The escape pass must not pin them to memory: with their address taken
// under a "memory" clobber, every call may have written them, and spin reads
// both lengths back from its frame on every round. unwrap takes a struct with a
// leading byte out of an option, ROUNDS times, with no allocation: four locals
// a round are escaped (two option temporaries, the struct in find and in
// unwrap), and the round must cost a branch for each, not a read of each word.
module main

import os

fn C.getpid() int

@[noinline]
fn spin(name string, rounds int) int {
	tail := name + '.'
	mut n := 0
	for _ in 0 .. rounds {
		n += C.getpid() & 1
		n += name.len
		n += tail.len
	}
	return n
}

struct Wide {
	tag u8
	buf []u8
}

@[noinline]
fn find(n int, b []u8) ?Wide {
	if n > 0 {
		w := Wide{
			tag: u8(n)
			buf: b
		}
		return w
	}
	return none
}

@[noinline]
fn unwrap(n int, b []u8) int {
	w := find(n, b) or { return -1 }
	return w.buf.len + int(w.tag)
}

fn main() {
	s := os.args[0] + 'x'
	rounds := (os.getenv_opt('ROUNDS') or { '1000' }).int()
	b := []u8{len: 5}
	mut acc := 0
	for i in 0 .. rounds {
		acc += unwrap(1 + (i & 3), b)
	}
	println('kept n=${spin(s, 1000) > 0} acc=${acc > 0}')
}
