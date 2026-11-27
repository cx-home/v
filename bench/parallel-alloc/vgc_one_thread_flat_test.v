// vgc_one_thread_flat_test.v — a lifted pacer over a sawtooth heap is timing-free: the same
// batches run the same collections whatever the mutator's speed
// (https://github.com/cx-home/v/issues/94, bar half 1: "a kit that allocates less must not read
// more collections or more user CPU than its parent").
//
// The lifted pacer (vgc_one_thread_lift doc) sizes its headroom from the decaying peak of the
// marked set, but the overhead band (pause against interval) still doubled and halved it above
// that, and a cheap reading ended the lift: which cycles read expensive depended on the
// mutator's timing, so the resting headroom followed the run, not the program. cx's put-docs
// (dev2 VGC_GCTRACE=2, 11-27): cx-core-data c8505ef4 caught doublings to 16-32 MB that its
// cheaper child 0ab46d60 missed (97-145 collections against 105-157 on the same batches).
// While lifted and under the live floor the headroom is clamp(peak, vgc_headroom_floor_lo,
// vgc_headroom_live_floor) on every cycle, and the lift ends only at a forced cycle.
// Shape: vgc_one_thread_sawtooth_test's (a 1 MB base, 24 batches of 11 MB kept + 21 MB churn).
// Bars:
//   (f) the cheaper mutator (work 0) and its parent (work 40) run the same batches within
//       one collection of each other: |cycles(0) - cycles(40)| <= 1 + cycles(40) / 50;
//   (g) VGC_ONE_LIFT_FLAT=0 restores the band (reported, not asserted).
//
// Run: ./v test bench/parallel-alloc/vgc_one_thread_flat_test.v
module main

import os

struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

const node_bytes = 48
const base_bytes = 1024 * 1024
const batch_live_mb = 11
const churn_per_batch_mb = 21
const batches = 24
const parent_work = 40

fn child(work int) {
	mut base := &Node(unsafe { nil })
	for i in 0 .. base_bytes / node_bytes {
		mut n := &Node{
			next: base
		}
		n.pad[0] = u64(i)
		base = n
	}
	keep_n := i64(batch_live_mb) * 1024 * 1024 / node_bytes
	churn_n := i64(churn_per_batch_mb) * 1024 * 1024 / node_bytes
	total := keep_n + churn_n
	mut sink := u64(0)
	mut x := u64(1)
	for _ in 0 .. batches {
		mut batch := &Node(unsafe { nil })
		mut kept := i64(0)
		for i in 0 .. total {
			// keep_n of the total, spread evenly through the batch
			if (i + 1) * keep_n / total > kept {
				mut n := &Node{
					next: batch
				}
				n.pad[0] = u64(i)
				batch = n
				kept++
			} else {
				mut t := &Node{}
				t.pad[1] = u64(i)
				sink += t.pad[1] & 1
			}
			for _ in 0 .. work {
				x = x * 6364136223846793005 + 1442695040888963407
			}
		}
		mut c := 0
		for n := batch; n != unsafe { nil }; n = n.next {
			c++
		}
		sink += u64(c) & 1
		batch = unsafe { nil }
	}
	mut kept := 0
	for n := base; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('DONE sink=${sink ^ (x & 1)} kept=${kept}')
}

struct Run {
	cycles    int
	mean_kb   u64
	peak_mark u64
}

fn run(work int, env string) Run {
	r := os.execute('VGC_SAW_CHILD=${work} VGC_GCTRACE=1 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	mut hs := []u64{}
	mut peak := u64(0)
	for l in r.output.split_into_lines() {
		if l.starts_with('[gc ') && l.contains(' headroom=') {
			hs << l.all_after(' headroom=').all_before('KB').u64()
			m := l.all_after(' marked=').all_before('MB').u64()
			if m > peak {
				peak = m
			}
		}
	}
	assert hs.len >= 8, 'too few collections (${hs.len}): ${r.output#[-400..]}'
	mut sum := u64(0)
	for h in hs {
		sum += h
	}
	return Run{
		cycles:    hs.len
		mean_kb:   sum / u64(hs.len)
		peak_mark: peak
	}
}

fn test_a_lifted_sawtooth_is_paced_the_same_at_any_mutator_speed() {
	w := os.getenv('VGC_SAW_CHILD')
	if w != '' {
		child(w.int())
		return
	}
	cheap := run(0, '')
	parent := run(parent_work, '')
	off_cheap := run(0, 'VGC_ONE_LIFT_FLAT=0 ')
	off_parent := run(parent_work, 'VGC_ONE_LIFT_FLAT=0 ')
	println('vgc_one_thread_flat: work 0 ${cheap.cycles} cycles (mean headroom ${cheap.mean_kb} KB), work ${parent_work} ${parent.cycles} (${parent.mean_kb} KB); VGC_ONE_LIFT_FLAT=0: ${off_cheap.cycles} / ${off_parent.cycles}')
	d := if cheap.cycles > parent.cycles { cheap.cycles - parent.cycles } else { parent.cycles - cheap.cycles }
	assert d <= 1 + parent.cycles / 50, '(f) the same batches ran ${cheap.cycles} collections at work 0 against ${parent.cycles} at work ${parent_work}: the pacer followed the mutator\'s timing'
}
