// vgc_thread_exit_returns_spans_test.v — a thread that exits hands the spans
// its cache holds to the other threads, so a program that spawns a thread per
// request allocates into the same spans the threads before it left, not into
// fresh ones (cx-home/v#65; vgc_thread_exit_cb in vlib/builtin/vgc_d_vgc.c.v,
// through vgc_cache_spans_release — the safe-region flush of cx-home/v#36
// read at the thread's exit).
//
// Before (5ccd272fb7), the exit callback drained the stash and released the
// slot, and the next registration cleared the slot's span pointers: every
// span the dead thread had touched — one fresh 8 KB span per size class it
// allocated from, a few objects in — stayed in use and out of every cache
// until a collection's sweep relinked it, and the pacer saw no growth to
// collect for (the garbage of a short thread is a few KB; the spans it
// strands are 25–85 KB). The repro of cx-home/v#65 read 85 MB resident after
// 1,000 spawned threads and 145 MB after 5,000 against 3.6 MB for the same
// work inline (the fork's own ./v -prod -gc e on 5ccd272fb7).
//
// The shape: the work of the issue's repro (a 1 KB buffer, twenty short
// strings, their join) done by `n` spawned threads that each exit, and inline
// `n` times by the main thread, each in its own process (a fresh heap); the
// probe is the arena space carved after the run (vgc_carved_probe: the
// pages the heap touched, which an arena never gives back) — the same garbage
// fills the same spans in both, so the difference is the spans the dead
// threads stranded. Red on 5ccd272fb7 (2,000 threads: 27,192 KB carved
// against the inline run's 1,016 KB); green on the lever: within half over
// the inline run plus 2 MB for the threads' own start-up objects.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_thread_exit_returns_spans_test.v
module main

import os
import sync

const n_threads = 2000

@[noinline]
fn work(mut wg sync.WaitGroup, i int) {
	mut s := []u8{len: 1024}
	s[0] = u8(i)
	mut parts := []string{}
	for j in 0 .. 20 {
		parts << 'x${j}${i}'
	}
	_ = parts.join(',')
	wg.done()
}

// run_shape does the work `n` times, spawned or inline, and answers the KB carved
// from the arenas at the end (every thread exited: the wait group).
fn run_shape(n int, spawned bool) int {
	mut wg := sync.new_waitgroup()
	for i in 0 .. n {
		wg.add(1)
		if spawned {
			spawn work(mut wg, i)
		} else {
			work(mut wg, i)
		}
		if spawned && i % 50 == 49 {
			// a breath for the threads to exit, as the repro of the issue
			os.execute('true')
		}
	}
	wg.wait()
	return int(vgc_carved_probe() / 1024)
}

fn test_a_thread_per_request_allocates_into_the_spans_its_predecessors_left() {
	if os.args.len > 2 {
		// the child: one shape, its answer on stdout
		n := os.args[1].int()
		spawned := os.args[2] == 'spawned'
		println('carved ${run_shape(n, spawned)}')
		exit(0)
	}
	exe := os.executable()
	inline_out := os.execute('${os.quoted_path(exe)} ${n_threads} inline')
	spawned_out := os.execute('${os.quoted_path(exe)} ${n_threads} spawned')
	assert inline_out.exit_code == 0, 'the inline child failed: ${inline_out.output}'
	assert spawned_out.exit_code == 0, 'the spawned child failed: ${spawned_out.output}'
	inline := carved_of(inline_out.output)
	spawned := carved_of(spawned_out.output)
	println('vgc_thread_exit_returns_spans: ${n_threads} requests — KB carved from the arenas after the run: inline ${inline}, one thread per request ${spawned}')
	assert inline > 0, 'the inline run read no carve: ${inline_out.output}'
	// the threads' own start-up objects (the closure, the thread record) are
	// carved too; half over the inline run and 2 MB cover them
	bound := inline + inline / 2 + 2048
	assert spawned <= bound, 'the spawned threads stranded their spans: ${spawned} KB carved against ${inline} KB inline (bound ${bound} KB)'
}

fn carved_of(output string) int {
	for line in output.split_into_lines() {
		if line.starts_with('carved ') {
			return line.all_after('carved ').trim_space().int()
		}
	}
	return -1
}

