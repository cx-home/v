// young/noscan.v — the builtin bulk mutators (array.v: push, push_many, set,
// insert, the grow copy) call the card barrier only for a buffer that can hold
// pointers (cx-home/v#56): a `.noscan_data` array's buffer is never scanned, so
// a store into it needs no card. Under VGC_YOUNG=1, after the first cycle (the
// regime on, the cards cleared), every store into an old []u8 leaves its
// page's card clean, and a pointer pushed into an old []&Node sets its card.
// Run by vgc_wb_noscan_test.v.
module main

struct Node {
	v int
}

@[noinline]
fn mk(i int) &Node {
	return &Node{
		v: i
	}
}

fn report(name string, p voidptr) {
	d := if vgc_card_dirty(p) { 1 } else { 0 }
	println('check=${name} dirty=${d}')
}

fn main() {
	mut bytes := []u8{cap: 65536} // a large buffer: its pages are its own
	mut ptrs := []&Node{cap: 16384}
	println('noscan=${bytes.flags.has(.noscan_data)} ptrs_noscan=${ptrs.flags.has(.noscan_data)}')
	gc_collect() // the regime on from the first cycle; the cards cleared
	report('after-collect', bytes.data)
	bytes << u8(1)
	report('u8-push', bytes.data)
	bytes[0] = 2
	report('u8-set', bytes.data)
	bytes << [u8(3), 4, 5]
	report('u8-push-many', bytes.data)
	bytes.insert(0, u8(9))
	report('u8-insert', bytes.data)
	mut small := []u8{cap: 8192}
	gc_collect()
	for i in 0 .. 8193 {
		small << u8(i)
	}
	report('u8-grow', small.data) // the grown buffer: the copy into it sets no card
	ptrs << mk(1)
	report('ptr-push', ptrs.data)
	println('done sum=${bytes[0] + bytes[1] + small[8192]} v=${ptrs[0].v}') // 9 + 2 + u8(8192) = 11
}
