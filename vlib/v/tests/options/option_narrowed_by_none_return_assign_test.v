// An option variable narrowed by `if x == none { return }` and then wrapped back
// into an option (assigned to an option var, declared through ?T(x), or used in
// an expression assigned to one) must read its payload: cgen wrote the raw
// _option_string inside builtin___option_ok, a C compile error
// (cx-private#1442's decoder hit it in cx-core-data's match_node_codec).

fn get(b bool) ?string {
	if b {
		return 'x'
	}
	return none
}

fn assign_back(b bool) ?string {
	s := get(b)
	if s == none {
		return none
	}
	mut out := ?string(none)
	out = s
	return out
}

fn assign_expr(b bool) ?string {
	s := get(b)
	if s == none {
		return none
	}
	mut out := ?string(none)
	out = s + 'y'
	return out
}

fn decl_cast(b bool) ?string {
	s := get(b)
	if s == none {
		return none
	}
	out := ?string(s)
	return out
}

fn get_int(b bool) ?int {
	if b {
		return 41
	}
	return none
}

fn assign_back_int(b bool) ?int {
	n := get_int(b)
	if n == none {
		return none
	}
	mut out := ?int(none)
	out = n + 1
	return out
}

fn test_assign_back() {
	assert assign_back(true) or { 'NONE' } == 'x'
	assert assign_back(false) or { 'NONE' } == 'NONE'
}

fn test_assign_expr() {
	assert assign_expr(true) or { 'NONE' } == 'xy'
	assert assign_expr(false) or { 'NONE' } == 'NONE'
}

fn test_decl_cast() {
	assert decl_cast(true) or { 'NONE' } == 'x'
	assert decl_cast(false) or { 'NONE' } == 'NONE'
}

fn test_assign_back_int() {
	assert assign_back_int(true) or { -1 } == 42
	assert assign_back_int(false) or { -1 } == -1
}
