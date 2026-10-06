// vgc_concurrent_collect_trace_test.v — the concurrent collector (-d vgc_concurrent)
// survives back-to-back collections and is traced as the stop-the-world one is.
//
// cx-private #1794: two back-to-back gc_collect() calls, then allocation, faulted in
// builtin____new_array_with_default_noscan (signal 11, 3 of 3 runs at 6a44b7173,
// gate on or off). The mark-termination sweep recycled an mcache-resident span its
// owner went on carving from; 768ba7f33f's vgc_protect_cached_spans before the
// concurrent sweep (#1757) is the fix — this test keeps it fixed.
//
// cx-private #1795: VGC_GCTRACE=1 printed one `[gc N]` line per collection on the
// stop-the-world path and none on the concurrent one, so the concurrent collector
// could not be gauged (measure_rss.cx's marked_peak reads these lines). Both paths
// now emit through vgc_gctrace_emit(), one line per completed collection.
//
// concurrent_collect_trace/back_to_back.v is the reproduction (REFUTE-1's flat
// driver at 32 MB); it prints gc_cycles(), the collections it saw complete.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_concurrent_collect_trace_test.v
module main

import os

fn build_fixture() string {
	src := os.join_path(@DIR, 'concurrent_collect_trace', 'back_to_back.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_concurrent_back_to_back_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -d vgc_concurrent -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn cycles_of(out string) int {
	for line in out.split_into_lines() {
		if line.starts_with('cycles=') {
			return line.all_after('cycles=').all_before(' ').int()
		}
	}
	return -1
}

fn test_back_to_back_collections_then_allocation() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	for n in [2, 3] {
		for run in 0 .. 3 {
			r := os.execute('NCOLLECT=${n} ${os.quoted_path(exe)}')
			assert r.exit_code == 0, 'NCOLLECT=${n} run ${run}: exit ${r.exit_code}: ${r.output}'
			assert cycles_of(r.output) >= n, 'NCOLLECT=${n}: ${r.output}'
		}
	}
}

fn test_gctrace_prints_one_line_per_concurrent_collection() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	for n in [0, 2] {
		r := os.execute('VGC_GCTRACE=1 NCOLLECT=${n} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, 'NCOLLECT=${n}: ${r.output}'
		cycles := cycles_of(r.output)
		assert cycles >= n, 'NCOLLECT=${n}: ${r.output}'
		lines := r.output.split_into_lines().filter(it.starts_with('[gc '))
		assert lines.len == cycles, 'NCOLLECT=${n}: ${lines.len} trace lines for ${cycles} collections: ${r.output}'
	}
}
