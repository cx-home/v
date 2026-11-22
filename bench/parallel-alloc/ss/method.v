// method.v — the program vgc_shadow_stack_cost_test.v builds -prod for its
// third test (cx-home/v#74 piece 5). Node is cx.Node's shape: a leading kind
// byte, an int, then the references; value is cx.Node.scalar_value's: a small
// method on a by-value receiver that answers a struct wider than two words by
// the receiver's kind. The interpreter calls such methods from hundreds of
// places and clang folds them into every caller; the receiver's escape must not
// lift the method's inline cost (kn15–18, 11-22: the receiver escape alone cost
// k-nucleotide 6 %: cx.Node.scalar_value called out of line at 1,192 sites
// against 107).
module main

import os

struct Node {
	kind  u8
	k2    int
	name  string
	items []Node
}

struct Val {
	kind u8
	i    i64
	f    f64
	s    string
}

fn (n Node) value() Val {
	if n.kind != 3 {
		return Val{}
	}
	match n.k2 {
		1 { return Val{
				kind: 1
				i:    i64(n.name.len)
			} }
		2 { return Val{
				kind: 2
				f:    f64(n.items.len)
			} }
		else { return Val{
				kind: 3
				s:    n.name
			} }
	}
}

@[noinline]
fn mk(i int) Node {
	return Node{
		kind:  u8(3)
		k2:    i % 4
		name:  'n${i}'
		items: []
	}
}

fn score(nodes []Node, k int) int {
	mut acc := 0
	for n in nodes {
		v := n.value()
		acc += int(v.i) + v.s.len + int(v.f) + k
	}
	return acc
}

fn main() {
	rounds := if os.args.len > 1 { os.args[1].int() } else { 0 }
	mut nodes := []Node{}
	for i in 0 .. 64 {
		nodes << mk(i)
	}
	mut acc := 0
	for r in 0 .. rounds {
		acc += score(nodes, r)
	}
	println(acc)
}
