// Regression battery for the `return f()!` direct-forward lowering (cgen
// return_stmt): when the callee's result type is exactly the enclosing
// function's return type, the call's result struct is returned directly —
// zero `_result_T` temporaries — instead of the generic unwrap/rewrap
// lowering. These tests pin the observable semantics the forward must
// preserve: error propagation, defer ordering on both paths, methods,
// generics, multi-return, and the mismatched-payload fallback (cx #327).

struct Big {
	a [50]i64
	s string
}

fn leaf(x int) !Big {
	if x < 0 {
		return error('neg ${x}')
	}
	return Big{
		s: x.str()
	}
}

fn mid(x int) !Big {
	match x {
		0 { return leaf(x + 1)! }
		else { return leaf(x)! }
	}
}

struct Log {
mut:
	s string
}

fn with_defer(mut l Log, x int) !Big {
	defer {
		l.s += 'D${x};'
	}
	return leaf(x)!
}

fn small(x int) !int {
	if x < 0 {
		return error('small neg')
	}
	return x + 1
}

fn promote(x int) !i64 {
	// callee `!int`, fn `!i64` — payloads differ, so the generic
	// rewrap lowering must still be used here.
	v := small(x)!
	return i64(v) * 2
}

fn gleaf[T](v T) !T {
	return v
}

fn gmid[T](v T) !T {
	return gleaf[T](v)!
}

struct Qq {
	base int
}

fn (q Qq) m(x int) !Big {
	return leaf(q.base + x)
}

fn (q Qq) fwd(x int) !Big {
	return q.m(x)!
}

fn two(x int) !(int, string) {
	if x < 0 {
		return error('two neg')
	}
	return x, x.str()
}

fn two_fwd(x int) !(int, string) {
	return two(x)!
}

fn test_forward_ok_path() {
	b := mid(0) or { panic('mid(0) errored: ${err}') }
	assert b.s == '1'
}

fn test_forward_error_propagates() {
	mut msg := ''
	mid(-5) or { msg = err.msg() }
	assert msg == 'neg -5'
}

fn test_defer_runs_before_forwarded_return_ok_and_error() {
	mut dlog := Log{}
	w := with_defer(mut dlog, 7) or { panic('with_defer(7) errored') }
	assert w.s == '7'
	assert dlog.s == 'D7;'
	mut msg := ''
	with_defer(mut dlog, -3) or { msg = err.msg() }
	assert msg == 'neg -3'
	assert dlog.s == 'D7;D-3;'
}

fn test_mismatched_payload_falls_back_to_rewrap() {
	assert promote(20) or { -1 } == 42
	mut msg := ''
	promote(-1) or { msg = err.msg() }
	assert msg == 'small neg'
}

fn test_generic_forward() {
	assert gmid[int](11) or { -1 } == 11
	assert gmid[string]('zz') or { 'no' } == 'zz'
}

fn test_method_forward() {
	q := Qq{
		base: 100
	}
	mb := q.fwd(5) or { panic('q.fwd errored') }
	assert mb.s == '105'
	mut msg := ''
	q.fwd(-200) or { msg = err.msg() }
	assert msg == 'neg -100'
}

fn test_multi_return_forward() {
	n, s := two_fwd(9) or { -1, 'e' }
	assert n == 9
	assert s == '9'
	n2, _ := two_fwd(-9) or { -1, 'e' }
	assert n2 == -1
}
