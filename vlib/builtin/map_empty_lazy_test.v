struct EmptyMapDenseLayout {
	key_bytes   int
	value_bytes int
mut:
	cap         int
	len         int
	deletes     u32
	all_deleted &u8 = unsafe { nil }
	keys        &u8 = unsafe { nil }
	values      &u8 = unsafe { nil }
}

struct EmptyMapLayout {
	key_bytes   int
	value_bytes int
mut:
	even_index      u32
	cached_hashbits u8
	shift           u8
	key_values      EmptyMapDenseLayout
	metas           &u32 = unsafe { nil }
	extra_metas     u32
	has_string_keys bool
	hash_fn         voidptr
	key_eq_fn       voidptr
	clone_fn        voidptr
	free_fn         voidptr
pub mut:
	len int
}


// map_empty_lazy_test.v — https://github.com/cx-home/cx-private/issues/2068: an empty map allocates
// nothing; it shares one zeroed metas block and has no key/value store until its first insert. A
// lib-free cx executable makes 48 empty __global maps in _vinit (29,160 B) and many more inside
// structs. Every read, delete, clear, clone, reserve and the first write behave as before.

fn layout(m &map[string]int) &EmptyMapLayout {
	return unsafe { &EmptyMapLayout(m) }
}

fn test_an_empty_map_allocates_nothing() {
	a := map[string]int{}
	b := map[int]string{}
	ra := unsafe { &EmptyMapLayout(&a) }
	rb := unsafe { &EmptyMapLayout(&b) }
	assert ra.key_values.cap == 0
	assert ra.key_values.keys == unsafe { nil } && ra.key_values.values == unsafe { nil }
	assert ra.metas == rb.metas, 'empty maps share one metas block'
}

fn test_reads_of_an_empty_map() {
	mut m := map[string]int{}
	assert m.len == 0
	assert 'x' !in m
	assert m['x'] == 0
	assert m.keys() == []string{}
	assert m.values() == []int{}
	v := m['y'] or { -1 }
	assert v == -1
	m.delete('x')
	m.clear()
	for _, _ in m {
		assert false
	}
	assert m.str() == '{}'
	assert m == map[string]int{}
	assert layout(&m).key_values.cap == 0
}

fn test_the_first_write_takes_its_own_storage() {
	mut a := map[string]int{}
	mut b := map[string]int{}
	shared_metas := layout(&a).metas
	a['one'] = 1
	assert layout(&a).metas != shared_metas
	assert layout(&b).metas == shared_metas, 'b still shares'
	assert b.len == 0 && 'one' !in b
	b['k'] += 5 // get_and_set on an empty map
	assert b['k'] == 5
	mut c := map[int]int{}
	c.reserve(100)
	for i in 0 .. 100 {
		c[i] = i * i
	}
	assert c.len == 100 && c[99] == 9801
	mut d := a.clone()
	d['two'] = 2
	assert a.len == 1 && d.len == 2
	mut e := map[string]int{}
	mut f := e.clone()
	f['z'] = 26
	assert e.len == 0 && layout(&e).metas == shared_metas && f['z'] == 26
	mut h := map[string]int{}
	h['a'] = 1
	h.clear()
	assert h.len == 0 && 'a' !in h
	h['b'] = 2
	assert h['b'] == 2
	mut big := map[string]string{}
	for i in 0 .. 5000 {
		big[i.str()] = i.str()
	}
	for i in 0 .. 5000 {
		if i % 2 == 0 {
			big.delete(i.str())
		}
	}
	assert big.len == 2500 && big['4999'] == '4999'
	gc_collect()
	assert big['1'] == '1' && unsafe { shared_metas[0] } == 0
	unsafe {
		mut fr := map[string]int{}
		fr.free()
	}
}
