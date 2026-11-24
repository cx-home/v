// vgc_many_workers_pause_test.v — the stop-the-world share of a many-worker
// batch with a small live set (cx-private#2040; the pacer's per-thread scaling
// in vgc_update_trigger, vlib/builtin/vgc_gc_d_vgc.c.v). many_workers/render.v
// runs 28 workers over a ~5 MB catalog, the shape of cx-examples'
// template-render and sql-roundtrips at `[par 28]`: dev2's ladder read 16-30 %
// of their wall stopped at k=28 (gc-*-k28.err), the goal 5-20 MB for most
// cycles. The per-thread headroom (cx-home/v#16) scales by the threads the
// alloc_gen stamp counted, and the stamp is ~1 MB a thread: once the goal is
// small, 28 workers each allocate a few hundred KB between two stops, the
// stamp counts none (pace nt=0 acct=28), the floor is not scaled, and the
// goal stays small — the 64 KB count (vgc_acct_threads) reads all 28.
// Red on 377e4407eb: after the start-up's ramp (the headroom reached 64 MB),
// cycles with 14+ workers over 64 KB at this stop or the one before fall
// under 32 MB of headroom (pace nt=0 acct=15 prev=16: 257 MB -> 16 MB) and
// re-climb; pbm1 x2: 69-87 cycles, 96-106 ms stopped. Green: none of them
// falls (at most one a run); 53-59 cycles, 82-85 ms. The stopped share of
// the workers' wall (summed pause= of VGC_GCTRACE over wall_us) is printed
// per run, not asserted: the rest of it is the 256 MB regime's own pause.
module main

import os

const workers = 28

fn build() string {
	src := os.join_path(@DIR, 'many_workers', 'render.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_many_workers_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -prod -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn field(line string, key string) i64 {
	if !line.contains(' ${key}=') {
		return -1
	}
	return line.all_after(' ${key}=').all_before(' ').trim_right('usKBMB').i64()
}

struct Run {
	wall_us  i64
	pause_us i64
	cycles   int
	small    int // of `paced`, the cycles whose headroom fell under 32 MB
	paced    int // cycles after the headroom reached 64 MB with acct >= workers / 2 at this stop or the one before
}

fn run(exe string) Run {
	r := os.execute('WORKERS=${workers} PAGES=4000000 VGC_GCTRACE=2 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines()
	done := lines.filter(it.starts_with('done '))
	assert done.len == 1, r.output
	mut pause := i64(0)
	mut cycles := 0
	mut small := 0
	mut paced := 0
	mut hr := i64(-1) // the headroom of the cycle whose marked= line came last; its pace line follows it
	mut ramped := false // the headroom reached 64 MB once (the start-up's ramp is over)
	for line in lines {
		if !line.starts_with('[gc ') {
			continue
		}
		if line.contains(' marked=') {
			cycles++
			pause += field(line, 'pause')
			hr = field(line, 'headroom')
			if hr >= 64 * 1024 {
				ramped = true
			}
			continue
		}
		if line.contains('] pace ') && hr >= 0 {
			if ramped && (field(line, 'acct') >= workers / 2 || field(line, 'prev') >= workers / 2) {
				paced++
				if hr < 32 * 1024 {
					small++
				}
			}
			hr = -1
		}
	}
	return Run{
		wall_us:  field(' ' + done[0], 'wall_us')
		pause_us: pause
		cycles:   cycles
		small:    small
		paced:    paced
	}
}

fn test_many_workers_keep_their_headroom_after_the_ramp() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	mut shares := []f64{}
	mut small := 0
	mut paced := 0
	for _ in 0 .. 3 {
		r := run(exe)
		share := f64(r.pause_us) * 100.0 / f64(r.wall_us)
		eprintln('wall_us=${r.wall_us} pause_us=${r.pause_us} cycles=${r.cycles} paced=${r.paced} small=${r.small} share=${share:.1f}%')
		shares << share
		small += r.small
		paced += r.paced
	}
	shares.sort()
	assert paced > 0, 'no cycle read the workers allocating'
	// the per-thread headroom follows the threads that allocated: at most one
	// small cycle a run (the cycle whose stop before was the start-up's)
	eprintln('median stopped share ${shares[1]:.1f}%')
	assert small <= 3, 'small=${small} of paced=${paced}: cycles paced from 14+ workers over 64 KB fell under 32 MB of headroom after the ramp'
}

fn test_the_per_thread_headroom_reads_the_threads_over_64_kb_at_two_stops() {
	assert vgc_scale_threads_selftest() == 0
}
