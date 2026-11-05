// tree.v — a binary tree's mark shared between the markers (cx-home/v#56
// lever 13, `-gc e`; the doc at vgc_work_balance in
// vlib/builtin/vgc_gc_d_vgc.c.v). A complete binary tree of DEPTH levels
// (2^DEPTH - 1 nodes of 32 bytes: two children and a payload) is built and
// held, then COLLECTS full cycles run (gc_collect), then the tree is walked
// back. A depth-first mark of a tree holds one pending child a level — a
// grey stack of about DEPTH entries, never a full 256-entry buffer — so
// the other markers get work only from the busy marker's balance. Prints
// `from=` (the first forced cycle) before the collections and `done nodes=
// sum= bad=` after the walk (bad= counts the nodes whose payload does not
// read back: a reclaimed-while-reachable node).
module main

import os

@[heap]
struct Node {
mut:
	left  &Node = unsafe { nil }
	right &Node = unsafe { nil }
	v     u64
}

fn build(depth int, v u64) &Node {
	if depth <= 1 {
		return &Node{
			v: v
		}
	}
	return &Node{
		left:  build(depth - 1, v * 2)
		right: build(depth - 1, v * 2 + 1)
		v:     v
	}
}

struct Count {
mut:
	nodes u64
	bad   u64
}

fn walk(n &Node, v u64, mut c Count) u64 {
	if n == unsafe { nil } {
		return 0
	}
	c.nodes++
	if n.v != v {
		c.bad++
	}
	return n.v + walk(n.left, v * 2, mut c) + walk(n.right, v * 2 + 1, mut c)
}

fn main() {
	depth := os.getenv_opt('DEPTH') or { '19' }.int()
	collects := os.getenv_opt('COLLECTS') or { '4' }.int()
	root := build(depth, 1)
	println('from=${gc_cycles()}')
	for _ in 0 .. collects {
		gc_collect()
	}
	mut c := Count{}
	sum := walk(root, 1, mut c)
	println('done nodes=${c.nodes} sum=${sum} bad=${c.bad} cycles=${gc_cycles()}')
}
