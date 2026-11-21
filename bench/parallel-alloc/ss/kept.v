// kept.v — the program vgc_shadow_stack_cost_test.v builds -prod (cx-home/v#74
// piece 5). spin holds a string parameter and a string local across calls the
// compiler cannot see through (C.getpid) and reads their lengths after each
// call. The escape pass must not pin them to memory: with their address taken
// under a "memory" clobber, every call may have written them, and spin reads
// both lengths back from its frame on every round.
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

fn main() {
	s := os.args[0] + 'x'
	println('kept n=${spin(s, 1000) > 0}')
}
