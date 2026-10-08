struct Node {
	v int
}

struct Holder {
	pp &&Node
	n  int
}

fn test_double_pointer_field_str() {
	n := &Node{1}
	h := Holder{
		pp: &n
		n:  2
	}
	s := h.str()
	assert s.contains('pp: &')
	assert s.contains('n: 2')
}
