// chain.v — the program vgc_shadow_stack_cost_test.v builds -prod for its
// second test (cx-home/v#74 piece 5). score takes a struct with a leading byte
// out of an option six times in a row and reads a field of each: twelve
// escaped locals in one function the compiler would otherwise fold into its
// caller. The interpreter's evaluators have this shape (a value type with a
// leading kind, unwrapped and read by field, call after call), and it is where
// the escape cost them 5 to 9 %: each escape was a branch and an asm to the
// inliner and a call that may write memory to every pass before the question
// is answered.
module main

import os

struct Wide {
	tag u8
	buf []u8
}

fn pick(w Wide, k int) ?Wide {
	if int(w.tag) + k > 0 {
		return w
	}
	return none
}

fn score(w Wide) int {
	mut acc := 0
	mut cur := w
	w0 := pick(cur, 1) or { return -1 }
	acc += w0.buf.len + int(w0.tag)
	cur = w0
	w1 := pick(cur, 2) or { return -2 }
	acc += w1.buf.len + int(w1.tag)
	cur = w1
	w2 := pick(cur, 3) or { return -3 }
	acc += w2.buf.len + int(w2.tag)
	cur = w2
	w3 := pick(cur, 4) or { return -4 }
	acc += w3.buf.len + int(w3.tag)
	cur = w3
	w4 := pick(cur, 5) or { return -5 }
	acc += w4.buf.len + int(w4.tag)
	cur = w4
	w5 := pick(cur, 6) or { return -6 }
	acc += w5.buf.len + int(w5.tag)
	cur = w5
	return acc
}

@[noinline]
fn caller(n int, b []u8) int {
	w := Wide{
		tag: u8(n)
		buf: b
	}
	return score(w)
}

fn main() {
	rounds := (os.getenv_opt('ROUNDS') or { '1000' }).int()
	b := []u8{len: 5}
	mut acc := 0
	for i in 0 .. rounds {
		acc += caller(1 + (i & 3), b)
	}
	println('chain acc=${acc > 0 || rounds == 0}')
}
