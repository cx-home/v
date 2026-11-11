// cx-home/v#70: under -gc e (the default vgc), Perceus freed a local slice of an
// array another object owns at the slice's last use (`Array_<T>_free(&sl)`), so the
// holder's elements were released and the next allocations reused them. A slice
// never owns its buffer; dropping it must not free the holder's elements.
struct Leaf {
	s string
}

@[heap]
struct Box {
mut:
	vals []Leaf
}

struct Handle {
	p &Box = unsafe { nil }
}

fn mk_handle(vals []Leaf) Handle {
	return Handle{
		p: &Box{
			vals: vals
		}
	}
}

fn (h Handle) raw() &Box {
	return h.p
}

fn churn() int {
	mut big := []Leaf{}
	for i in 0 .. 100000 {
		big << Leaf{
			s: 'x${i}'
		}
	}
	return big.len
}

fn test_a_local_slice_of_a_held_array_leaves_the_holder_whole() {
	mut vs := []Leaf{}
	for i in 0 .. 5 {
		vs << Leaf{
			s: 'v${i}'
		}
	}
	got := mk_handle(vs)
	m := got.raw()
	sl := m.vals[1..3]
	assert sl.len == 2
	assert churn() == 100000
	for i in 0 .. 5 {
		assert got.raw().vals[i].s == 'v${i}'
	}
}

fn test_a_local_slice_read_then_dropped_leaves_the_holder_whole() {
	mut vs := []Leaf{}
	for i in 0 .. 5 {
		vs << Leaf{
			s: 'w${i}'
		}
	}
	got := mk_handle(vs)
	m := got.raw()
	sl := m.vals[2..]
	assert sl[0].s == 'w2'
	assert churn() == 100000
	assert got.raw().vals[2].s == 'w2'
	assert got.raw().vals[4].s == 'w4'
}

@[heap]
struct Doc {
mut:
	name  string
	vals  []Leaf
	nests [][]Leaf
}

struct DocHandle {
	p &Doc = unsafe { nil }
}

fn (h DocHandle) raw() &Doc {
	return h.p
}

fn mk_doc() DocHandle {
	mut vs := []Leaf{}
	mut ns := [][]Leaf{}
	for i in 0 .. 4 {
		vs << Leaf{
			s: 'd${i}'
		}
		ns << [Leaf{
			s: 'n${i}'
		}]
	}
	return DocHandle{
		p: &Doc{
			name:  'doc-name-${vs.len}'
			vals:  vs
			nests: ns
		}
	}
}

fn test_a_local_copy_of_a_held_array_field_leaves_the_holder_whole() {
	got := mk_doc()
	m := got.raw()
	all := m.vals
	assert all.len == 4
	assert churn() == 100000
	assert got.raw().vals[3].s == 'd3'
}

fn test_a_local_element_of_a_held_array_of_arrays_leaves_the_holder_whole() {
	got := mk_doc()
	m := got.raw()
	inner := m.nests[2]
	assert inner[0].s == 'n2'
	assert churn() == 100000
	assert got.raw().nests[2][0].s == 'n2'
}

fn test_a_local_substring_of_a_held_string_leaves_the_holder_whole() {
	got := mk_doc()
	m := got.raw()
	sub := m.name[4..8]
	assert sub == 'name'
	assert churn() == 100000
	assert got.raw().name == 'doc-name-4'
}

fn test_a_branch_valued_slice_of_a_held_array_leaves_the_holder_whole() {
	got := mk_doc()
	m := got.raw()
	sl := if m.vals.len > 2 { m.vals[1..3] } else { []Leaf{} }
	assert sl.len == 2
	assert churn() == 100000
	assert got.raw().vals[1].s == 'd1'
	assert got.raw().vals[2].s == 'd2'
}

fn (h DocHandle) both() ([]Leaf, [][]Leaf) {
	return h.p.vals, h.p.nests
}

fn test_a_multi_return_of_held_arrays_leaves_the_holder_whole() {
	got := mk_doc()
	a, b := got.both()
	assert a.len == 4
	assert b.len == 4
	assert churn() == 100000
	assert got.raw().vals[0].s == 'd0'
	assert got.raw().nests[1][0].s == 'n1'
}
