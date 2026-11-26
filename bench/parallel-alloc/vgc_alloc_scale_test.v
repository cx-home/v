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
// the run, and on a box with fewer than 20 cpus). Bar: the median 16-thread cycles per allocation <= 1.10x the
// median 1-thread one, both phases at EQUAL heap headroom a thread (operator
// ruling BAR-2040-HEADROOM (a), 11-26: a measurement-method fix, the 1.10
// unchanged). The pacer's own headroom differs by phase: several allocating
// threads get its several-threads clamp, 4 MB a thread (64 MB at 16, marked
// ~0 here), one thread its one-thread clamp (256 KB, cx-home/v#14), and each
// phase starts at the headroom the other left. The run pins both at
// headroom_per_thread_mb, the 16-thread phase's own 4 MB a thread
// (scale.v: HEADROOM_PER_THREAD_MB).
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

fn test_sixteen_threads_allocate_at_most_ten_percent_more_cycles_per_allocation_than_one() {
	exe := build()
	r :=
		os.execute('HEADROOM_PER_THREAD_MB=${headroom_per_thread_mb} THREADS=${threads} ALLOCS=2000000 ROUNDS=3 ${os.quoted_path(exe)}')
	println(r.output)
	assert r.exit_code == 0, r.output
	rounds := r.output.split_into_lines().filter(it.starts_with('round '))
	assert rounds.len == 3, r.output
	t1 := rounds.map(field(it, 't1 cyc/alloc'))
	tk := rounds.map(field(it, 't${threads} cyc/alloc'))
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
	ratio := median(tk) / median(t1)
	println('median t1 ${median(t1):.2f} t${threads} ${median(tk):.2f} cycles/alloc: ratio ${ratio:.3f} (bar 1.10; ${headroom_per_thread_mb} MB headroom a thread in both phases)')
	assert ratio <= 1.10
}
