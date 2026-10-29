// cards.v — the old generation's card barrier, exercised (cx-home/v#56 step 1,
// `-gc e`; the regime's doc at vgc_young_mode in vlib/builtin/vgc_d_vgc.c.v).
// An Old record is built and a full cycle forced, so it is old; then, each
// after a forced cycle (which clears every card), a fresh record's only
// reference is stored into it by one of the paths a pointer takes into a heap
// object (permanent/perm_gen.v's (a)-(h)), and the page the store landed on
// must read dirty (vgc_card_dirty) where it read clean after the cycle:
//   (a) a pointer field            old.hold = r          (old's page)
//   (b) a field of a nested value  old.inner.f = r       (old's page)
//   (c) an old array buffer        old.arr[k] = r        (the buffer's page)
//   (d) a fixed array inside       old.farr[k] = r       (old's page)
//   (e) a push into an old buffer  old.list << r         (the buffer's page),
//       then a push that regrows                         (old's page: the
//       header's data store)
//   (f) an old map                 old.m[k] = r          (the value buffer:
//       its page is not addressable from here, so the count of set cards)
//   (g) a store through a pointer  *p = r, p = &old.hold (old's page)
//   (h) a cycle in the middle of a statement: old.hold = mk_collect(r) — the
//       cycle between the barrier call before the statement and the store
//       clears every card; the call after the store sets old's page's again
//   (i) an array buffer allocated 70 MB past a cycle (an arena mapped since
//       it), stored into after the next cycle: the gate widened over its
//       arena at that stop.
// A stack address never reads dirty, nor any page right after a cycle. Prints
// one `check=<name> dirty=<0|1>` line per check and the two counts of (f);
// the test judges them per regime (VGC_YOUNG=1: dirty where a store landed;
// unset: never, the gate stays the permanent range and nothing is permanent).
module main

@[heap]
struct Rec {
mut:
	a u64
	p &Rec = unsafe { nil }
}

struct Inner {
mut:
	f &Rec = unsafe { nil }
}

@[heap]
struct Old {
mut:
	hold  &Rec = unsafe { nil }
	inner Inner
	arr   []&Rec
	farr  [4]&Rec
	list  []&Rec
	m     map[int]&Rec
}

fn mk(i u64) &Rec {
	return &Rec{
		a: i
	}
}

fn mk_collect(i u64) &Rec {
	r := mk(i)
	gc_collect()
	return r
}

fn report(name string, p voidptr) {
	d := if vgc_card_dirty(p) { 1 } else { 0 }
	println('check=${name} dirty=${d}')
}

fn main() {
	mut old := &Old{
		arr:  []&Rec{len: 8, init: unsafe { nil }}
		list: []&Rec{cap: 1}
	}
	for k in 0 .. 64 {
		old.m[k] = mk(u64(k))
	}
	gc_collect()
	report('after-collect', old)
	stack := u64(7)
	report('stack', &stack)
	// (a)
	old.hold = mk(1)
	report('a-field', old)
	gc_collect()
	report('a-cleared', old)
	// (b)
	old.inner.f = mk(2)
	report('b-nested', old)
	gc_collect()
	// (c)
	old.arr[3] = mk(3)
	report('c-array', old.arr.data)
	gc_collect()
	// (d)
	old.farr[2] = mk(4)
	report('d-fixed', old)
	gc_collect()
	// (e) the cap-1 buffer was allocated with old: the first push lands in it
	buf := old.list.data
	old.list << mk(5)
	report('e-push-buffer', buf)
	gc_collect()
	old.list << mk(6)
	report('e-push-regrow', old)
	gc_collect()
	// (f)
	c0 := vgc_cards_dirty()
	old.m[9] = mk(7)
	c1 := vgc_cards_dirty()
	println('cards_after_collect=${c0} cards_after_store=${c1}')
	gc_collect()
	// (g)
	mut p := &old.hold
	unsafe {
		*p = mk(8)
	}
	report('g-pointer', old)
	gc_collect()
	// (h)
	old.hold = mk_collect(9)
	report('h-mid-statement', old)
	// (i)
	gc_collect()
	mut big := [][]&Rec{}
	for _ in 0 .. 70 {
		big << []&Rec{len: 131072, init: unsafe { nil }}
	}
	gc_collect()
	report('i-arena-cleared', big[69].data)
	big[69][0] = mk(10)
	report('i-arena', big[69].data)
	println('done hold=${old.hold.a} inner=${old.inner.f.a} arr=${old.arr[3].a} farr=${old.farr[2].a} list=${old.list.len} m=${old.m.len} big=${big.len} ${big[69][0].a}')
}
