// Refutation: every POINTER-BEARING array must stay scanned under -gc e
// (cx-private #1629). Each shape holds the ONLY references to 256 x 64 KiB
// payloads; retained = marked(holder alive) - marked(holder dropped) must be
// ~ the payload total. A no-scan buffer reads ~0 (its referents get swept).
module main

const n_pay = 256
const pay_bytes = 64 * 1024
const pay_total = i64(n_pay) * pay_bytes

struct Big {
mut:
	w [8192]u64 // 64 KiB, pointer-free
}

type BigRef = &Big

type BigPtrAlias = &u8

struct WithAliasPtr {
	id int
	p  BigRef
}

struct WithStr {
	id int
	s  string
}

struct Wrap {
	inner WithStr
}

type Sum = Big2 | int

struct Big2 {
	s string
}

interface Has {
	get() string
}

fn (b Big2) get() string {
	return b.s
}

struct Holder {
mut:
	refs   []BigRef
	ptrs   []&Big
	aps    []BigPtrAlias
	was    []WithAliasPtr
	strs   []string
	recs   []WithStr
	wraps  []Wrap
	us     []usize
	is_    []isize
	vps    []voidptr
	sums   []Sum
	ifs    []Has
	nested [][]u8
	fixed  [][2]string
	opts   []?string
}

fn live() i64 {
	mut best := i64(0)
	for i in 0 .. 3 {
		gc_collect()
		l := i64(gc_heap_usage().total_bytes)
		if i == 0 || l < best {
			best = l
		}
	}
	return best
}

@[noinline]
fn mk_big() &Big {
	mut b := &Big{}
	b.w[0] = 7
	return b
}

@[noinline]
fn mk_str(i int) string {
	return 'x'.repeat(pay_bytes - 1) + (i % 10).str()
}

@[noinline]
fn drop_all(mut h Holder) {
	h.refs = []BigRef{}
	h.ptrs = []&Big{}
	h.aps = []BigPtrAlias{}
	h.was = []WithAliasPtr{}
	h.strs = []string{}
	h.recs = []WithStr{}
	h.wraps = []Wrap{}
	h.us = []usize{}
	h.is_ = []isize{}
	h.vps = []voidptr{}
	h.sums = []Sum{}
	h.ifs = []Has{}
	h.nested = [][]u8{}
	h.fixed = [][2]string{}
	h.opts = []?string{}
}

fn retained(fill fn (mut Holder)) i64 {
	mut h := &Holder{}
	base := live()
	_ = base
	fill(mut h)
	with := live()
	drop_all(mut h)
	without := live()
	return with - without
}

fn check(name string, fill fn (mut Holder)) bool {
	got := retained(fill)
	ok := got > pay_total / 2
	println('PTRSCAN ${name}: retained=${got} of ${pay_total} ${if ok { 'GREEN' } else { 'RED' }}')
	return ok
}

@[noinline]
fn f_refs(mut h Holder) {
	for _ in 0 .. n_pay {
		h.refs << BigRef(mk_big())
	}
}

@[noinline]
fn f_ptrs(mut h Holder) {
	for _ in 0 .. n_pay {
		h.ptrs << mk_big()
	}
}

@[noinline]
fn f_aps(mut h Holder) {
	for _ in 0 .. n_pay {
		h.aps << BigPtrAlias(&u8(mk_big()))
	}
}

@[noinline]
fn f_was(mut h Holder) {
	for i in 0 .. n_pay {
		h.was << WithAliasPtr{i, BigRef(mk_big())}
	}
}

@[noinline]
fn f_strs_push(mut h Holder) {
	for i in 0 .. n_pay {
		h.strs << mk_str(i)
	}
}

@[noinline]
fn f_strs_len(mut h Holder) {
	h.strs = []string{len: n_pay}
	for i in 0 .. n_pay {
		h.strs[i] = mk_str(i)
	}
}

@[noinline]
fn f_strs_insert_prepend(mut h Holder) {
	h.strs = []string{}
	for i in 0 .. n_pay {
		if i % 2 == 0 {
			h.strs.insert(0, mk_str(i))
		} else {
			h.strs.prepend(mk_str(i))
		}
	}
}

@[noinline]
fn f_strs_clone_slice_reverse(mut h Holder) {
	mut tmp := []string{}
	for i in 0 .. n_pay {
		tmp << mk_str(i)
	}
	a := tmp.clone()
	b := a[0..n_pay].clone()
	h.strs = b.reverse()
	unsafe { tmp.reset() }
}

@[noinline]
fn f_strs_map(mut h Holder) {
	ints := []int{len: n_pay, init: index}
	h.strs = ints.map(mk_str(it))
}

@[noinline]
fn f_strs_filter_sorted(mut h Holder) {
	mut tmp := []string{}
	for i in 0 .. n_pay {
		tmp << mk_str(i)
	}
	h.strs = tmp.filter(it.len > 0).sorted()
	unsafe { tmp.reset() }
}

@[noinline]
fn f_strs_push_many_spread(mut h Holder) {
	mut tmp := []string{}
	for i in 0 .. n_pay - 1 {
		tmp << mk_str(i)
	}
	mut x := [mk_str(9)]
	x << tmp
	h.strs = [...x, mk_str(1)]
	unsafe { tmp.reset() }
	unsafe { x.reset() }
}

@[noinline]
fn f_recs(mut h Holder) {
	for i in 0 .. n_pay {
		h.recs << WithStr{i, mk_str(i)}
	}
}

@[noinline]
fn f_wraps(mut h Holder) {
	for i in 0 .. n_pay {
		h.wraps << Wrap{WithStr{i, mk_str(i)}}
	}
}

@[noinline]
fn f_us(mut h Holder) {
	for _ in 0 .. n_pay {
		h.us << usize(voidptr(mk_big()))
	}
}

@[noinline]
fn f_is(mut h Holder) {
	for _ in 0 .. n_pay {
		h.is_ << isize(voidptr(mk_big()))
	}
}

@[noinline]
fn f_vps(mut h Holder) {
	for _ in 0 .. n_pay {
		h.vps << voidptr(mk_big())
	}
}

@[noinline]
fn f_sums(mut h Holder) {
	for i in 0 .. n_pay {
		h.sums << Sum(Big2{mk_str(i)})
	}
}

@[noinline]
fn f_ifs(mut h Holder) {
	for i in 0 .. n_pay {
		h.ifs << Has(Big2{mk_str(i)})
	}
}

@[noinline]
fn f_nested(mut h Holder) {
	for _ in 0 .. n_pay {
		h.nested << []u8{len: pay_bytes, init: 3}
	}
}

@[noinline]
fn f_fixed(mut h Holder) {
	for i in 0 .. n_pay / 2 {
		h.fixed << [mk_str(i), mk_str(i + 1)]!
	}
}

@[noinline]
fn f_opts(mut h Holder) {
	for i in 0 .. n_pay {
		h.opts << ?string(mk_str(i))
	}
}

fn test_pointer_bearing_arrays_stay_scanned() {
	mut red := []string{}
	cases := {
		'[]BigRef (type BigRef = &Big)':          f_refs
		'[]&Big':                                 f_ptrs
		'[]BigPtrAlias (type = &u8)':             f_aps
		'[]WithAliasPtr (field BigRef)':          f_was
		'[]string push':                          f_strs_push
		'[]string{len}':                          f_strs_len
		'[]string insert/prepend':                f_strs_insert_prepend
		'[]string clone/slice/reverse':           f_strs_clone_slice_reverse
		'[]int.map -> []string':                  f_strs_map
		'[]string filter/sorted':                 f_strs_filter_sorted
		'[]string push_many/spread':              f_strs_push_many_spread
		'[]struct{int,string}':                   f_recs
		'[]struct{struct{int,string}}':           f_wraps
		'[]usize':                                f_us
		'[]isize':                                f_is
		'[]voidptr':                              f_vps
		'[]sumtype':                              f_sums
		'[]interface':                            f_ifs
		'[][]u8':                                 f_nested
		'[][2]string':                            f_fixed
		'[]?string':                              f_opts
	}
	for name, f in cases {
		if !check(name, f) {
			red << name
		}
	}
	assert red.len == 0, 'pointer-bearing arrays allocated no-scan: ${red}'
}
