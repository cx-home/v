// vgc_rootdiag_test.v — -d vgc_rootdiag names the root word that keeps a structure
// alive (cx-home/v#46). A conservative stack word that roots a dead structure has
// cost a bisect each time (cx-private#1941, the fmt_8k lane slot, cx-home/v#45):
// the diagnostic build charges every root word with the bytes it alone reaches and
// keeps the cycle's heaviest (vgc_rootdiag_top), reporting the heavy ones on stderr
// with their frame. Here one stack word holds a ~10 MB list through a collection:
// the heaviest root must be that stack word, charged with the whole list.
//
// Run: ./v -gc e -d vgc_rootdiag test bench/parallel-alloc/vgc_rootdiag_test.v
// (without -d vgc_rootdiag the test checks nothing: the default build carries no diag)
module main

const rd_nodes = 20000

@[heap]
struct RNode {
mut:
	next &RNode = unsafe { nil }
	pad  [62]u64
}

@[noinline]
fn rd_build(n int) &RNode {
	mut head := &RNode{}
	mut cur := head
	for _ in 1 .. n {
		mut x := &RNode{}
		cur.next = x
		cur = x
	}
	return head
}

@[noinline]
fn rd_hold_and_collect(n int) (u32, u64, i64, int) {
	mut head := rd_build(n)
	gc_collect()
	cat, bytes, _, off := vgc_rootdiag_top()
	mut len := 0
	mut p := head
	for p != unsafe { nil } {
		len++
		p = p.next
	}
	return cat, bytes, off, len
}

fn test_the_heaviest_root_is_the_stack_word_holding_the_list() {
	$if vgc_rootdiag ? {
		cat, bytes, off, len := rd_hold_and_collect(rd_nodes)
		assert len == rd_nodes
		// a stack word (kind 10 + thread), below the stack top, charged with the list
		assert cat >= 10
		assert off > 0
		assert bytes >= u64(rd_nodes) * u64(sizeof(RNode))
	}
}
