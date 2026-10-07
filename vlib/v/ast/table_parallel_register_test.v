// cx-private #1864: parallel cgen workers share one Table. A worker that meets
// a new instantiation registers a type symbol (find_or_register_* ->
// register_sym) while the other workers look types up by name (find_sym,
// find_type_idx). Unguarded, the insert's robin-hood shuffle or growth of
// type_idxs made a concurrent lookup of an EXISTING name miss: method_call's
// `table.find_sym(receiver_type_name)` answered none, the call lost its
// `builtin__` prefix, and cc stopped on `call to undeclared function
// 'array_clear'` (a different builtin each run, only under load).
module ast

const pre_registered = 3000
const readers = 6
const writers = 4
const per_writer = 4000

struct ReadResult {
	misses int
	reads  int
}

fn reader_loop(t &Table, stop &bool) ReadResult {
	mut misses := 0
	mut reads := 0
	for {
		for i in 0 .. pre_registered {
			name := 'main.Pre${i}'
			if sym := t.find_sym(name) {
				if sym.name != name {
					misses++
				}
			} else {
				misses++
			}
			if t.find_type_idx('string') != string_type_idx {
				misses++
			}
			reads += 2
		}
		if unsafe { *stop } {
			break
		}
	}
	return ReadResult{misses, reads}
}

fn writer_loop(mut t Table, w int) []int {
	mut idxs := []int{cap: per_writer}
	for i in 0 .. per_writer {
		idxs << t.register_sym(TypeSymbol{
			kind: .struct
			name: 'main.W${w}_${i}'
			cname: 'main__W${w}_${i}'
			mod:  'main'
			info: Struct{}
		})
		// the shape cgen's workers take: a new []T for a fresh element type
		t.find_or_register_array(idx_to_type(idxs.last()))
	}
	return idxs
}

fn test_lookups_of_registered_names_never_miss_while_workers_register() {
	mut t := new_table()
	for i in 0 .. pre_registered {
		t.register_sym(TypeSymbol{
			kind:  .struct
			name:  'main.Pre${i}'
			cname: 'main__Pre${i}'
			mod:   'main'
			info:  Struct{}
		})
	}
	t.begin_parallel_registration()
	mut stop := false
	mut rthreads := []thread ReadResult{}
	for _ in 0 .. readers {
		rthreads << spawn reader_loop(t, &stop)
	}
	mut wthreads := []thread []int{}
	for w in 0 .. writers {
		wthreads << spawn writer_loop(mut t, w)
	}
	written := wthreads.wait()
	stop = true
	results := rthreads.wait()
	t.end_parallel_registration()
	mut misses := 0
	mut reads := 0
	for r in results {
		misses += r.misses
		reads += r.reads
	}
	assert reads > 0
	assert misses == 0, '${misses} of ${reads} lookups of already-registered names missed'
	// no registration lost, none shares an index with another
	mut seen := map[int]bool{}
	for w, idxs in written {
		assert idxs.len == per_writer
		for i, idx in idxs {
			name := 'main.W${w}_${i}'
			assert idx !in seen, '${name} shares index ${idx}'
			seen[idx] = true
			assert t.type_symbols[idx].name == name
			assert t.find_type_idx(name) == idx
			assert t.find_type_idx('[]${name}') > 0
		}
	}
}
