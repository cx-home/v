// vgc_xthread_free_test.v — a spawned thread that only reads and frees what
// other threads allocated is a registered mutator from its first instruction
// (cx-home/v#26).
//
// Registration with the collector was lazy — at a thread's first allocation.
// A consumer thread that pops a channel, verifies the records and free()s them
// never allocates, so it ran the whole program outside the stop-the-world: not
// parked, not mach-suspended, its stack and registers never scanned, its frees
// racing mark and sweep. The message it held across a collection was rooted by
// nothing the collector saw; its records were swept while live and handed out
// again, and its free() then cleared a live object's bit. The fix registers
// every spawned thread in its wrapper, before the first use of its arguments,
// and vgc_free registers a caller that is not yet registered.
//
// xthread_free/xfree.v is the reproducer. Two shapes, both at T=16:
//   - HOLD: each consumer holds one message for 50 ms across ~6 collections.
//     Before the fix: every consumer reports idx=-1 (never registered) and
//     most held messages read wrong (5-7 of 8 per run on dev2); after: every
//     consumer has a cache slot and no record is touched.
//   - plain: the filed shape (bad 1-41 per run under load before the fix).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_xthread_free_test.v
module main

import os

fn build_fixture() string {
	src := os.join_path(@DIR, 'xthread_free', 'xfree.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_xthread_free_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -enable-globals -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn test_consumers_are_registered_and_held_messages_survive() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	for run in 0 .. 2 {
		r := os.execute('HOLD_EVERY=300 HOLD_US=50000 T=16 STEPS=60000 ${os.quoted_path(exe)}')
		assert r.exit_code == 0, 'hold run ${run}: exit ${r.exit_code}: ${r.output}'
		mut holds := 0
		for line in r.output.split_into_lines() {
			if !line.starts_with('HOLD c') {
				continue
			}
			holds++
			idx := line.all_after('idx=').all_before(' ').int()
			assert idx >= 0, 'hold run ${run}: a consumer was never registered: ${line}'
			assert line.contains('id_ok=true'), 'hold run ${run}: a held message was touched: ${line}'
		}
		assert holds == 8, 'hold run ${run}: ${holds} consumers held (want 8): ${r.output}'
		assert r.output.contains(' bad=0 '), 'hold run ${run}: ${r.output}'
	}
}

fn test_filed_shape_is_clean() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('T=16 STEPS=100000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, 'exit ${r.exit_code}: ${r.output}'
	assert r.output.contains(' bad=0 '), r.output
}
