// vtest vflags: -gc e
// A by-value receiver or parameter of a @[heap] struct is copied to the heap on
// entry (HEAP(T, _v_toheap_x)) only when the function needs its address: when
// the body reads the parameter's fields and nothing else, the call allocates
// nothing. cx's Element is @[heap], and each `e.anchor()`-style accessor read
// copied the whole Element (96+ bytes a call) before this.
// The cases that take the address (&p, a pointer-receiver method, the value
// passed on or returned) still get their heap copy, so the address stays valid
// after the call returns.

struct Meta {
	anchor ?string
}

@[heap]
struct Elem {
	name  string
	kids  []int
	meta  &Meta = unsafe { nil }
	count int
	tags  map[string]int
	maybe ?int
}

@[noinline]
fn (e Elem) anchor() ?string {
	if isnil(e.meta) {
		return none
	}
	return e.meta.anchor
}

@[noinline]
fn (e Elem) width() int {
	mut w := e.name.len + e.count
	for k in e.kids {
		w += k
	}
	if m := e.maybe {
		w += m
	}
	return w + e.tags.len
}

@[noinline]
fn elem_name_len(e Elem, extra int) int {
	return e.name.len + extra
}

// address-taking shapes: these must keep the heap copy

@[noinline]
fn (e &Elem) self_ptr() &Elem {
	return e
}

@[noinline]
fn (e Elem) via_ptr_method() &Elem {
	return e.self_ptr()
}

@[noinline]
fn (e Elem) addr() &Elem {
	return &e
}

@[noinline]
fn keep(e Elem) []&Elem {
	return [&e]
}

fn test_a_field_read_of_a_heap_struct_value_param_allocates_nothing() {
	els := [Elem{
		name: 'a'
	}, Elem{
		name: 'bb'
		kids: [1, 2]
	}]
	mut s := 0
	n := 10000
	gc_collect()
	t0 := gc_total_allocated()
	for i in 0 .. n {
		if a := els[i % 2].anchor() {
			s += a.len
		}
		s += els[i % 2].width()
		s += elem_name_len(els[i % 2], 1)
	}
	grew := gc_total_allocated() - t0
	assert s == n / 2 * (1 + 2) + n / 2 * (5 + 3), 's=${s}' // width a=1 bb=5; name_len+1 a=2 bb=3
	assert grew < 64, 'field-read calls on a @[heap] by-value param allocated ${grew} bytes over ${n} x 3 calls (${f64(grew) / f64(n * 3)} a call)'
}

fn test_a_heap_struct_value_param_whose_address_is_taken_still_lives_on() {
	e := Elem{
		name: 'k'
		count: 7
	}
	p1 := e.addr()
	p2 := e.via_ptr_method()
	kept := keep(e)
	gc_collect()
	// churn the stack and the heap so a pointer to a dead frame would read garbage
	mut junk := []Elem{}
	for i in 0 .. 1000 {
		junk << Elem{
			name: 'junk${i}'
			count: i
		}
	}
	assert p1.name == 'k' && p1.count == 7
	assert p2.name == 'k' && p2.count == 7
	assert kept[0].name == 'k' && kept[0].count == 7
	assert voidptr(p1) != voidptr(&e)
	assert junk.len == 1000
}
