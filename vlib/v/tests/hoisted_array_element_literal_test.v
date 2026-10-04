// A string literal inside an array element that cgen hoists into a temporary
// (`[wrap(cs.join(' '))]` needs one: a method call on an array) must keep its
// bytes. expr_string_with_cast cut the pushed element back out of the buffer at
// a position saved BEFORE the hoist and trimmed it, so when that stale position
// fell on the literal's space, `' '` was emitted as `_S("")` (cx-private #1642).
struct Node {
	name string
	kids []Node
}

fn wrap(s string) Node {
	return Node{
		name: s
	}
}

fn mk(name string, kids []Node) Node {
	return Node{
		name: name
		kids: kids
	}
}

fn test_hoisted_array_element_keeps_its_space_literal() {
	cs := ['a', 'b']
	mut i := []Node{}
	mut it := []Node{}
	mut itm := []Node{}
	mut item := []Node{}
	i << mk('x', [wrap(cs.join(' '))])
	it << mk('x', [wrap(cs.join(' '))])
	itm << mk('x', [wrap(cs.join(' '))])
	item << mk('x', [wrap(cs.join(' '))])
	assert i[0].kids[0].name == 'a b'
	assert it[0].kids[0].name == 'a b'
	assert itm[0].kids[0].name == 'a b'
	assert item[0].kids[0].name == 'a b'
}
