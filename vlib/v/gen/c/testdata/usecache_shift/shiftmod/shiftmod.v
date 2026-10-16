// cx-home/v#49 fixture: every construct whose generated C names a type index —
// a layer built from it must emit the same C whatever the importing universe's
// type numbering is.
module shiftmod

pub struct Lit {
pub:
	v int
}

pub struct Pair {
pub:
	a string
	b []int
}

pub struct Nested {
pub:
	inner Node
}

pub type Node = Lit | Pair | Nested | string

pub interface Shape {
	area() f64
}

pub struct Sq {
pub:
	s f64
}

pub fn (q Sq) area() f64 {
	return q.s * q.s
}

pub struct Circ {
pub:
	r f64
}

pub fn (c Circ) area() f64 {
	return 3.0 * c.r * c.r
}

pub fn make(i int) Node {
	return match i % 4 {
		0 { Node(Lit{i}) }
		1 { Node(Pair{'p', [i]}) }
		2 { Node(Nested{Node(Lit{i})}) }
		else { Node('s${i}') }
	}
}

pub fn kind(n Node) string {
	if n is Lit {
		return 'lit'
	}
	return match n {
		Lit { 'lit' }
		Pair { 'pair' }
		Nested { 'nested ' + kind(n.inner) }
		string { 'str' }
	}
}

pub fn same(a Node, b Node) bool {
	return a == b
}

pub fn show(n Node) string {
	return n.str()
}

pub fn shapes() []Shape {
	return [Shape(Sq{2}), Circ{1}]
}

pub fn same_shape(a Shape, b Shape) bool {
	return a == b
}

pub fn shape_name(s Shape) string {
	return typeof(s).name
}

pub fn field_types[T]() []int {
	mut out := []int{}
	$for f in T.fields {
		out << f.typ
	}
	return out
}

pub fn pair_field_types() []int {
	return field_types[Pair]()
}

pub fn variant_count(n Node) int {
	mut c := 0
	$for v in Node.variants {
		if n is v {
			c++
		}
	}
	return c
}
