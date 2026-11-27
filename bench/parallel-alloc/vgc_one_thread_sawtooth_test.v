// vgc_one_thread_sawtooth_test.v — one allocating thread whose live set rises
// and falls batch by batch is paced by the size its live set reaches, not by
// where in the batch each collection happens to land
// (https://github.com/cx-home/v/issues/94, gating
// https://github.com/cx-home/cx-core-data/issues/98).
//
// cx's put-docs writes its documents in batches: the batch's rows stay live
// until the batch is flushed, then all of it is garbage. Its marked set at a
// collection runs 1-13 MB depending on where in the batch the collection
// falls. The lifted one-thread pacer (vgc_one_thread_lift doc) sized its
// headroom by the marked set of the last collection (1 x marked, at least
// 4 MB), so the first collections of each batch ran at 4 MB of headroom over a
// small mark. Which of the cycles fell early in a batch decided the count:
// a cheaper kit (cx-core-data 0ab46d60) read 136-173 collections against its
// parent's 93-115 on dev1 (443d9e3151, 11-26).
//
// Shape: the child keeps a 1 MB base and runs `batches` batches. Each batch
// allocates batch_live_mb of 48-byte nodes it keeps until the batch ends,
// interleaved with churn_per_batch_mb of 48-byte transients, then drops the
// batch. work 0: its collections cost far over a tenth of its time (the lift).
// Bars:
//   (d) the mean headroom over the run's collections is at least 3/4 of the
//       largest marked set the run read: the pacer holds the size the batches
//       reach. The head paces at ~1 x the marked set of the moment (mean
//       ~5-6 MB against a 12 MB peak).
//   (e) a cheaper mutator runs no more collections than its parent on the
//       same batches: cycles(work 0) <= cycles(work parent_work) x 1.10 + 2.
//
// Run: ./v test bench/parallel-alloc/vgc_one_thread_sawtooth_test.v
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

fn test_a_one_thread_sawtooth_is_paced_by_the_size_its_batches_reach() {
	w := os.getenv('VGC_SAW_CHILD')
	if w != '' {
		child(w.int())
		return
	}
	env := os.getenv('VGC_SAW_ENV')
	cheap := run(0, env)
	parent := run(parent_work, env)
	bound_d := cheap.peak_mark * 1024 * 3 / 4
	bound_e := f64(parent.cycles) * 1.10 + 2
	println('vgc_one_thread_sawtooth: work 0 ${cheap.cycles} cycles (mean headroom ${cheap.mean_kb} KB, peak marked ${cheap.peak_mark} MB); work ${parent_work} ${parent.cycles} cycles (mean ${parent.mean_kb} KB, peak ${parent.peak_mark} MB) (bars: (d) work 0 mean >= ${bound_d} KB; (e) work 0 <= ${bound_e:.1f} cycles)')
	assert cheap.mean_kb >= bound_d, '(d) the lifted pacer sized its headroom by the marked set of the moment: mean ${cheap.mean_kb} KB over a batch live set reaching ${cheap.peak_mark} MB (bar ${bound_d} KB)'
	assert f64(cheap.cycles) <= bound_e, '(e) the cheaper mutator ran ${cheap.cycles} collections against its parent\'s ${parent.cycles} on the same batches'
}
