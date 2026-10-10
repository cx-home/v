// vgc_global_root_test.v — a heap object reachable only from a global (a module
// const) survives collections (cx-home/v#20). vgc finds the globals through
// vgc_data_segments: mach-o segments on darwin, dl_iterate_phdr on Linux and
// the BSDs, the writable PE sections on Windows. Windows answered no segment
// before, so a const's array was swept under it and its cells reused.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_global_root_test.v
module main

const table = build_table()

fn build_table() []string {
	mut t := []string{cap: 4096}
	for i in 0 .. 4096 {
		t << 'cell-${i}-' + 'x'.repeat(i % 37)
	}
	return t
}

fn churn() int {
	mut n := 0
	for i in 0 .. 20000 {
		s := 'junk-${i}-' + 'y'.repeat(i % 53)
		n += s.len
	}
	return n
}

fn test_a_const_held_array_survives_collections() {
	assert table.len == 4096
	for _ in 0 .. 8 {
		gc_collect()
		_ := churn()
	}
	for i in 0 .. 4096 {
		assert table[i] == 'cell-${i}-' + 'x'.repeat(i % 37), 'table[${i}] was swept and reused: ${table[i]}'
	}
}
