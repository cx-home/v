// vgc_start_carve_test.v — what touching many size classes at start-up costs
// the heap.
//
// A span class's first span is a whole page (8 KB). A program whose module
// initialisers allocate a few objects in each of many size classes carved a
// page per span class touched: start_carve/cells.v allocates one object in each
// of the 32 smallest classes (8 .. 1024 B), scanned and pointer-free, 64 span
// classes and 20,688 B allocated in all, and carved 507,904 B (62 pages) more
// than the same program allocating nothing (`-d start_carve_control`). Measured
// on 394a12489, macOS arm64.
//
// The bar: at most 131,072 B (16 pages) carved for those 64 span classes. How it
// was chosen: a program that must carve at most 262,144 B at its first mark
// while touching 67 span classes (the case this was measured from) has room for
// the class overhead only beside its own objects; half the budget each gives
// 131,072 B for about 64 span classes. At one page per class the 64 cost 4x that.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_start_carve_test.v
module main

import os

const carve_bar = u64(131072)

fn carved_by(src string, flags string) (u64, string) {
	exe := os.join_path(os.vtmp_dir(), 'vgc_start_carve_${os.getpid()}')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('${os.quoted_path(@VEXE)} -gc e ${flags} -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	run := os.execute(os.quoted_path(exe))
	assert run.exit_code == 0, 'exit ${run.exit_code}: ${run.output}'
	out := run.output.trim_space()
	return out.all_after('carved=').all_before(' ').u64(), out
}

fn test_touching_64_span_classes_at_start_up_carves_at_most_the_bar() {
	src := os.join_path(@DIR, 'start_carve', 'cells.v')
	with, wout := carved_by(src, '')
	without, cout := carved_by(src, '-d start_carve_control')
	println('cells:   ${wout}')
	println('control: ${cout}')
	assert wout.ends_with('cells=64'), wout
	assert with >= without, '${wout} / ${cout}'
	cost := with - without
	println('64 span classes at start-up carve ${cost} B (bar ${carve_bar})')
	assert cost <= carve_bar, '64 span classes carved ${cost} B at start-up (bar ${carve_bar})'
}

// cx-private#2068: a program's own start-up in main — cx's built program reads
// its payload and marks its first start-up point in main, after vgc_init() —
// carves a page per span class it touches once vgc_init() has put back the
// exact size tables, though its heap is still far under the ladder's bound
// (vgc_start_ladder_limit). The same 64 span classes touched by main, against
// main touching none, carve at most the same bar.
fn test_touching_64_span_classes_in_main_under_the_ladder_bound_carves_at_most_the_bar() {
	src := os.join_path(@DIR, 'start_carve', 'cells.v')
	with, wout := carved_by(src, '-d start_carve_main')
	without, cout := carved_by(src, '-d start_carve_main -d start_carve_control')
	println('cells in main: ${wout}')
	println('control:       ${cout}')
	assert wout.ends_with('cells=64'), wout
	assert with >= without, '${wout} / ${cout}'
	cost := with - without
	println('64 span classes touched by main carve ${cost} B (bar ${carve_bar})')
	assert cost <= carve_bar, '64 span classes touched by main carved ${cost} B (bar ${carve_bar})'
}
