// An option or result value is written by builtin _option_ok / _option_none /
// _result_ok through a `_option*` / `_result*` pointer into a typed wrapper
// (`_option_Node`, `_result_Node`) and then read back through the typed wrapper.
// The header store must be one gcc -O2 -fstrict-aliasing cannot drop: a struct
// assignment through the generic pointer type was, after inlining, a store of
// another type than every later read, and a frame's `key ?Node` read as none
// (https://github.com/cx-home/cx-private/issues/2019: a γ group lost its first
// member under gcc 11.4 -O2). Red: `v -cc gcc -cflags -O2 test` on Linux.
struct Payload {
	a u64
	b u64
	s string
}

struct Frame {
mut:
	idx []int
	key ?Payload
}

@[noinline]
fn payload_of(i int) !Payload {
	if i < 0 {
		return error('negative')
	}
	return Payload{
		a: u64(i)
		b: u64(i) * 3
		s: 'k${i}'
	}
}

fn build(n int, has_key bool, mut out []Frame) ! {
	for i in 0 .. n {
		mut fr := Frame{
			idx: [i]
		}
		if has_key {
			fr.key = payload_of(i)!
		}
		out << fr
	}
}

fn test_an_option_field_set_after_none_reads_back_set() {
	for _ in 0 .. 50 {
		mut frames := []Frame{}
		build(64, true, mut frames) or { panic(err) }
		assert frames.len == 64
		for i, fr in frames {
			k := fr.key or { panic('frame ${i}: key read as none') }
			assert k.a == u64(i)
			assert k.b == u64(i) * 3
			assert k.s == 'k${i}'
		}
	}
}

fn opt_of(i int) ?Payload {
	if i % 3 == 0 {
		return none
	}
	return Payload{
		a: u64(i)
	}
}

fn test_option_and_result_wrappers_keep_their_state() {
	mut some := 0
	mut nones := 0
	for i in 0 .. 300 {
		if p := opt_of(i) {
			assert p.a == u64(i)
			some++
		} else {
			nones++
		}
		r := payload_of(i) or { panic(err) }
		assert r.a == u64(i)
	}
	assert some == 200
	assert nones == 100
	if _ := payload_of(-1) {
		assert false
	}
}
