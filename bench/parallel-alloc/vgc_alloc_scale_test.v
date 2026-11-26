// vgc_alloc_scale_test.v — the cycles one small allocation costs when 16
// threads allocate at once against one thread alone, in one process
// (cx-private#2040: cx [par 16] sql-roundtrips spends 1.48-1.50x the CPU per
// unit of [par 1] on dev2 with EQUAL instructions — backend memory stalls).
// The symbolized profile named a stall on the allocation fast path:
// vgc_acct_alloc's load of vgc_acct_flush_cur, a global read by every
// allocation, sat on one 128-byte line (Apple Silicon's) with counters the
// mutators write (vgc_pool_kind_steps, vgc_arena_of_scans,
// vgc_pool_aged_steps, vgc_gc_owner): every write by one thread evicts the
// line from the 15 others, and their next allocation waits on it.
// alloc_scale/scale.v runs the same allocations on 1 thread, then on 16,
// three rounds interleaved, and prints the process's cycles per allocation
// for each (proc_pid_rusage; 0 where not kept — the test then only checks
// the run, and on a box with fewer than 20 cpus). Both phases run at EQUAL
// heap headroom a thread (operator ruling BAR-2040-HEADROOM (a), 11-26):
// headroom_per_thread_mb, the 16-thread phase's own several-threads clamp
// (scale.v: HEADROOM_PER_THREAD_MB). The pacer's own headroom differs by
// phase (one thread gets its one-thread clamp, 256 KB, cx-home/v#14).
// Bar (operator ruling VGC-SCALE-NET (c), 11-26; this test is a lever's guard,
// not cx-private#2040's own bar): the median 16-thread cycles per allocation
// over the median 1-thread one is at most the no-collector hardware control's
// ratio + 0.10. The control is v-writer9's ring.c shape (cycles.h
// vgc_as_ring_phase: the same 32-byte objects written through a private ring
// of the same per-thread size, headroom_per_thread_mb, no collector), run in
// each round of the same process right after the allocator's phases and
// graded by its own medians. A working set of 4 MB a thread costs cache
// misses on dev2 (L2 16 MB per 5-core cluster) that no allocator can avoid.
module main

import os
import runtime

const threads = 16

// the heap headroom a thread both phases run at (MB): the pacer's several-
// threads clamp (VGC_HEADROOM_FLOOR_LO_MB's default), which the 16-thread phase gets
const headroom_per_thread_mb = 4

fn build() string {
	src := os.join_path(@DIR, 'alloc_scale', 'scale.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_alloc_scale_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -prod -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn field(line string, key string) f64 {
	return line.all_after(' ${key}=').all_before(' ').f64()
}

fn median(xs []f64) f64 {
	mut s := xs.clone()
	s.sort()
	return s[s.len / 2]
}

fn test_sixteen_threads_allocate_within_ten_points_of_the_hardware_control_ratio() {
	exe := build()
	r :=
		os.execute('HEADROOM_PER_THREAD_MB=${headroom_per_thread_mb} CONTROL_KB=${headroom_per_thread_mb * 1024} THREADS=${threads} ALLOCS=2000000 ROUNDS=3 ${os.quoted_path(exe)}')
	println(r.output)
	assert r.exit_code == 0, r.output
	rounds := r.output.split_into_lines().filter(it.starts_with('round '))
	assert rounds.len == 3, r.output
	t1 := rounds.map(field(it, 't1 cyc/alloc'))
	tk := rounds.map(field(it, 't${threads} cyc/alloc'))
	ctl := r.output.split_into_lines().filter(it.starts_with('control '))
	assert ctl.len == 3, r.output
	x1 := ctl.map(field(it, 't1 cyc/slot'))
	xk := ctl.map(field(it, 't${threads} cyc/slot'))
	if median(t1) == 0 {
		println('no cycle counter on this platform: the run is checked, not the ratio')
		return
	}
	if runtime.nr_cpus() < threads + 4 {
		// 16 threads on fewer cores time-share them: the ratio then reads the
		// scheduler, not the allocator (ardec-dev3 has 8)
		println('${runtime.nr_cpus()} cpus < ${threads + 4}: the run is checked, not the ratio')
		return
	}
	assert median(x1) > 0, r.output
	ratio := median(tk) / median(t1)
	control := median(xk) / median(x1)
	bar := control + 0.10
	// beside the grade, not graded: the allocator's extra cycles over the control's
	// extra, as a ratio of the 1-thread allocation ((t16 - (c16 - c1)) / t1)
	additive := (median(tk) - (median(xk) - median(x1))) / median(t1)
	println('median t1 ${median(t1):.2f} t${threads} ${median(tk):.2f} cycles/alloc: ratio ${ratio:.3f}; control (${headroom_per_thread_mb} MB ring a thread, no collector) t1 ${median(x1):.2f} t${threads} ${median(xk):.2f} cycles/slot: ratio ${control:.3f}; bar ${bar:.3f} (control + 0.10, VGC-SCALE-NET (c)); additive net ${additive:.3f} (not graded)')
	assert ratio <= bar
}
