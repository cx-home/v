// const_array_static_test.v — https://github.com/cx-home/cx-private/issues/2068: a const array literal whose
// elements are all literals (strings, numbers, bools, chars) is emitted as static C data, not copied into
// the heap by _vinit: the array points at that data and carries `.nofree` (never `.managed`). A lib-free
// cx executable built 309 such string arrays (59.5 KB) + 47 number arrays before main. A mutable copy grows
// into the heap and leaves the const as it was; slices, clones and reads answer as before.

const static_names = ['alpha', 'beta', 'gamma', 'd\te"lta', 'ünï']
const static_u32s = [u32(1), 2, 0xffff_ffff]
const static_ints = [3, -4, 5]
const static_f64s = [1.5, -2.25]
const static_bools = [true, false]
const static_runes = [`a`, `ß`]
const computed_names = ['a' + 'b', static_names[0]]

fn test_a_literal_const_array_is_static_data() {
	for name, a in {
		'names': static_names
	} {
		assert a.flags.has(.nofree), '${name}: flags ${a.flags}'
		assert !a.flags.has(.managed), name
	}
	assert static_u32s.flags.has(.nofree)
	assert static_ints.flags.has(.nofree)
	assert static_f64s.flags.has(.nofree)
	assert static_bools.flags.has(.nofree)
	assert static_runes.flags.has(.nofree)
	assert static_names.len == 5 && static_names.cap == 5
}

fn test_static_const_arrays_read_as_before() {
	assert static_names == ['alpha', 'beta', 'gamma', 'd\te"lta', 'ünï']
	assert static_names[3].len == 7
	assert static_names[4] == 'ünï'
	assert static_u32s[2] == 0xffff_ffff
	assert static_ints == [3, -4, 5]
	assert static_f64s[1] == -2.25
	assert static_bools == [true, false]
	assert static_runes[1] == `ß`
	assert computed_names == ['ab', 'alpha']
	assert static_names.join(',').starts_with('alpha,beta')
	assert 'gamma' in static_names
	assert static_names.index('beta') == 1
	assert static_names[1..3] == ['beta', 'gamma']
	assert static_names.map(it.len) == [5, 4, 5, 7, 5]
	assert static_ints.filter(it > 0) == [3, 5]
}

fn test_a_mutable_copy_grows_into_the_heap_and_leaves_the_const() {
	mut c := static_names.clone()
	c << 'epsilon'
	c[0] = 'ALPHA'
	assert c.len == 6
	assert !c.flags.has(.nofree)
	assert static_names[0] == 'alpha' && static_names.len == 5
	mut n := static_ints.clone()
	n.sort()
	assert n == [-4, 3, 5]
	assert static_ints == [3, -4, 5]
	mut s := static_names[1..]
	s << 'zeta'
	assert s.len == 5
	assert static_names.len == 5 && static_names[1] == 'beta'
	gc_collect()
	assert static_names[4] == 'ünï' && c[5] == 'epsilon'
}
