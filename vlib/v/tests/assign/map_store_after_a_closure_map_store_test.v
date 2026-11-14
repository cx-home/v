// cx-home/v#71: a map index store of a closure (`cases['a'] = fn () {}`) left its map_set entry on
// g.cur_indexexpr, so the NEXT map index store of a pointer value in the program (`j.named[k] = st`)
// was emitted without its ` = ` and with a stray ` })` (a C syntax error; on Linux the store's table-cols test
// generated those functions in that order).
struct Ss {
mut:
	x int
}

struct Jj {
mut:
	named map[string]&Ss
}

fn make_cases() map[string]fn () {
	mut cases := map[string]fn (){}
	cases['a'] = fn () {}
	return cases
}

fn get_or_make(mut j Jj, k string) &Ss {
	if st := j.named[k] {
		return st
	}
	st := &Ss{
		x: 7
	}
	j.named[k] = st
	return st
}

fn test_a_map_store_after_a_map_store_of_a_closure_keeps_its_assignment() {
	c := make_cases()
	assert c.len == 1
	mut j := Jj{}
	a := get_or_make(mut j, 'a')
	b := get_or_make(mut j, 'a')
	assert a == b
	assert j.named.len == 1
}
