// cx-private#1910 (bump H): the concurrent-mark write barrier on `shared` targets.
// A shared value lives in a heap wrapper (`__shared__T*`, the value in `->val`).
// The barrier emitted `vgc_wb_store((h->results)->data)` for `h.results[i] = v`,
// which cc refused ("no member named 'data' in 'struct __shared__Array_voidptr'":
// vlib/sync/pool failed to compile under -gc e), and for `h.results = v` it
// dirtied h, not the wrapper the store goes into. Now: `->val.data` for a shared
// array element, the wrapper for a shared local or field.
//
//   ../../v -gc e test bench/parallel-alloc/vgc_wb_shared_test.v
module main

struct Node {
	v int
mut:
	next &Node = unsafe { nil }
}

struct Holder {
mut:
	results shared []voidptr
}

struct Box {
mut:
	p &Node = unsafe { nil }
}

fn test_shared_targets_compile_and_keep_their_values() {
	mut h := &Holder{}
	shared a := []&Node{}
	shared b := Box{}
	for round in 0 .. 200 {
		lock h.results {
			h.results = []voidptr{len: 8, init: unsafe { nil }}
			for i in 0 .. 8 {
				h.results[i] = voidptr(&Node{v: round * 8 + i})
			}
		}
		lock a {
			a = []&Node{len: 8, init: &Node{v: -1}}
			for i in 0 .. 8 {
				a[i] = &Node{v: round * 8 + i}
			}
		}
		lock b {
			b.p = &Node{v: round}
		}
		// garbage between the stores, so collections run while the values are live
		mut junk := []&Node{cap: 512}
		for i in 0 .. 512 {
			junk << &Node{v: i}
		}
		if round % 20 == 0 {
			gc_collect()
		}
		rlock h.results {
			for i in 0 .. 8 {
				assert unsafe { &Node(h.results[i]) }.v == round * 8 + i
			}
		}
		rlock a {
			for i in 0 .. 8 {
				assert a[i].v == round * 8 + i
			}
		}
		rlock b {
			assert b.p.v == round
		}
	}
}
