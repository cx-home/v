// `unsafe { m.value_ptr(key) }` — by-ref map get (compiles to a direct
// map_get_check: one probe, no value copy, no value-sized zero literal).
// The returned reference points into the map's storage and is invalidated
// by any subsequent map write — these tests copy out / re-lookup around
// writes, exactly the discipline call sites must follow.

struct Payload {
	tag string
mut:
	hits int
}

fn test_hit_returns_ref_into_storage() {
	mut m := map[string]Payload{}
	m['k'] = Payload{
		tag: 'alpha'
	}
	p := unsafe { m.value_ptr('k') }
	assert p != unsafe { nil }
	assert p.tag == 'alpha'
	// an in-place write through the map is visible through the ref
	// (no insert/delete/rehash in between)
	m['k'].hits = 3
	assert p.hits == 3
}

fn test_miss_returns_nil() {
	mut m := map[string]Payload{}
	m['k'] = Payload{
		tag: 'alpha'
	}
	assert unsafe { m.value_ptr('absent') } == unsafe { nil }
	// missing key inserts NOTHING (unlike `&m[k]` which zero-fills)
	assert m.len == 1
}

fn test_scalar_maps() {
	mut mi := map[int]int{}
	mi[7] = 70
	pi := unsafe { mi.value_ptr(7) }
	assert pi != unsafe { nil }
	assert *pi == 70
	assert unsafe { mi.value_ptr(8) } == unsafe { nil }
}

fn test_copy_out_survives_rehash() {
	mut m := map[string]Payload{}
	m['k'] = Payload{
		tag: 'keep'
	}
	p := unsafe { m.value_ptr('k') }
	v := *p // copy out BEFORE the map grows
	for i in 0 .. 1000 {
		m['g${i}'] = Payload{
			tag: 'grow'
		}
	}
	assert v.tag == 'keep'
	// the map's own value is still intact too (fresh lookup)
	p2 := unsafe { m.value_ptr('k') }
	assert p2.tag == 'keep'
}
