// An expr_string() whose start was moved by a statement hoist
// (an array literal element evaluated into a temporary before the `<<`) cut
// the output at a stale offset, inside the hoisted temporary, and the
// trim_space() of the cut text dropped whitespace at the boundary — for one
// length of the statement prefix that boundary is the space in `' '`, and
// `cs.join(' ')` compiled as `Array_string_join(cs, _S(""))`. The forty
// probes differ only in the pushed array's name length, so one of them puts
// the stale offset on that space.
module main

struct Node {
	s    string
	kids []Node
	p    &int = unsafe { nil }
}

fn wrap(s string) Node {
	return Node{
		s: s
	}
}

fn mk(name string, attrs []string, kids []Node) Node {
	return Node{
		s:    name
		kids: kids
	}
}

fn probe_1(cs []string) []Node {
	mut i := []Node{}
	i << mk('k', [], [wrap(cs.join(' '))])
	return i
}

fn probe_2(cs []string) []Node {
	mut ii := []Node{}
	ii << mk('k', [], [wrap(cs.join(' '))])
	return ii
}

fn probe_3(cs []string) []Node {
	mut iii := []Node{}
	iii << mk('k', [], [wrap(cs.join(' '))])
	return iii
}

fn probe_4(cs []string) []Node {
	mut iiii := []Node{}
	iiii << mk('k', [], [wrap(cs.join(' '))])
	return iiii
}

fn probe_5(cs []string) []Node {
	mut iiiii := []Node{}
	iiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiii
}

fn probe_6(cs []string) []Node {
	mut iiiiii := []Node{}
	iiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiii
}

fn probe_7(cs []string) []Node {
	mut iiiiiii := []Node{}
	iiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiii
}

fn probe_8(cs []string) []Node {
	mut iiiiiiii := []Node{}
	iiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiii
}

fn probe_9(cs []string) []Node {
	mut iiiiiiiii := []Node{}
	iiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiii
}

fn probe_10(cs []string) []Node {
	mut iiiiiiiiii := []Node{}
	iiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiii
}

fn probe_11(cs []string) []Node {
	mut iiiiiiiiiii := []Node{}
	iiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiii
}

fn probe_12(cs []string) []Node {
	mut iiiiiiiiiiii := []Node{}
	iiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiii
}

fn probe_13(cs []string) []Node {
	mut iiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiii
}

fn probe_14(cs []string) []Node {
	mut iiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiii
}

fn probe_15(cs []string) []Node {
	mut iiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiii
}

fn probe_16(cs []string) []Node {
	mut iiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiii
}

fn probe_17(cs []string) []Node {
	mut iiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiii
}

fn probe_18(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiii
}

fn probe_19(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiii
}

fn probe_20(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiii
}

fn probe_21(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiii
}

fn probe_22(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiii
}

fn probe_23(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiii
}

fn probe_24(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_25(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_26(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_27(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_28(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_29(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_30(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_31(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_32(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_33(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_34(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_35(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_36(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_37(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_38(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_39(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [wrap(cs.join(' '))])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn probe_40(cs []string) []Node {
	mut iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii := []Node{}
	iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii << mk('k', [], [
		wrap(cs.join(' ')),
	])
	return iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii
}

fn test_join_space_literal_survives_hoisting() {
	cs := ['a', 'b']
	assert probe_1(cs)[0].kids[0].s == 'a b'
	assert probe_2(cs)[0].kids[0].s == 'a b'
	assert probe_3(cs)[0].kids[0].s == 'a b'
	assert probe_4(cs)[0].kids[0].s == 'a b'
	assert probe_5(cs)[0].kids[0].s == 'a b'
	assert probe_6(cs)[0].kids[0].s == 'a b'
	assert probe_7(cs)[0].kids[0].s == 'a b'
	assert probe_8(cs)[0].kids[0].s == 'a b'
	assert probe_9(cs)[0].kids[0].s == 'a b'
	assert probe_10(cs)[0].kids[0].s == 'a b'
	assert probe_11(cs)[0].kids[0].s == 'a b'
	assert probe_12(cs)[0].kids[0].s == 'a b'
	assert probe_13(cs)[0].kids[0].s == 'a b'
	assert probe_14(cs)[0].kids[0].s == 'a b'
	assert probe_15(cs)[0].kids[0].s == 'a b'
	assert probe_16(cs)[0].kids[0].s == 'a b'
	assert probe_17(cs)[0].kids[0].s == 'a b'
	assert probe_18(cs)[0].kids[0].s == 'a b'
	assert probe_19(cs)[0].kids[0].s == 'a b'
	assert probe_20(cs)[0].kids[0].s == 'a b'
	assert probe_21(cs)[0].kids[0].s == 'a b'
	assert probe_22(cs)[0].kids[0].s == 'a b'
	assert probe_23(cs)[0].kids[0].s == 'a b'
	assert probe_24(cs)[0].kids[0].s == 'a b'
	assert probe_25(cs)[0].kids[0].s == 'a b'
	assert probe_26(cs)[0].kids[0].s == 'a b'
	assert probe_27(cs)[0].kids[0].s == 'a b'
	assert probe_28(cs)[0].kids[0].s == 'a b'
	assert probe_29(cs)[0].kids[0].s == 'a b'
	assert probe_30(cs)[0].kids[0].s == 'a b'
	assert probe_31(cs)[0].kids[0].s == 'a b'
	assert probe_32(cs)[0].kids[0].s == 'a b'
	assert probe_33(cs)[0].kids[0].s == 'a b'
	assert probe_34(cs)[0].kids[0].s == 'a b'
	assert probe_35(cs)[0].kids[0].s == 'a b'
	assert probe_36(cs)[0].kids[0].s == 'a b'
	assert probe_37(cs)[0].kids[0].s == 'a b'
	assert probe_38(cs)[0].kids[0].s == 'a b'
	assert probe_39(cs)[0].kids[0].s == 'a b'
	assert probe_40(cs)[0].kids[0].s == 'a b'
}
