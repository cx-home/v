// vgc_one_thread_cost_test.v — one allocating thread whose collections cost
// more than the band's grow line is not held to the one-thread quarter, and a
// cheaper mutator does not pay more collections than its parent
// (https://github.com/cx-home/v/issues/94, gating
// https://github.com/cx-home/cx-core-data/issues/98).
//
// The adaptive floor (cx-home/v#14) paces ONE allocating thread to the quarter
// (vgc_one_thread_term: 25 % of the marked set): the band's live-set cap and
// the floor are both the term, so the band's "over a tenth: double the
// headroom" (vgc_update_trigger) has no room and the goal stays marked x 1.25
// however much the collections cost. cx's put-docs (cx-core-data 0ab46d60, a
// ~4 MB live set) paced 375-478 collections at ~1-2 MB of headroom against
// 70-81 with VGC_HEADROOM_ADAPTIVE_FLOOR=0, and spent 20-25 % more user CPU;
// the cheaper commit read 7-10 % slower than its parent because its run paced
// at the quarter more often.
//
// Shape: the child holds a 4 MB live set (48-byte linked nodes: a mark of
// pointers) and allocates churn_mb of 48-byte transients, with `work` rounds of
// arithmetic between allocations. It reports its collections from the
// VGC_GCTRACE=1 lines.
// Bars:
//   (a) the cheapest mutator (work 0: its collections cost far over a tenth of
//       its time) paces with a mean headroom of at least half the live set — its
//       collections are at most 2 x churn / live + 8 (the climb); the lift's
//       GOGC=100 term (1 x marked) runs ~200. The head holds it at the quarter:
//       640 on pbm1.
//   (b) a cheaper mutator does not run more collections than its parent on the
//       same live set and the same allocation: cycles(work 0) <= cycles(work
//       parent_work) x 1.10 + 2.
//   (c) a mutator whose collections are cheap (work heavy_work over
//       heavy_churn_mb: well under a tenth of its time) keeps the quarter — the memory rows the term exists
//       for (cx-examples#296/#297, cx-home/v#56): the headroom of its last
//       quarter of collections stays at most 2 x the term.
//   (d) RULING (OPERATOR) 94-CARVE (b), 07:45 ET 11-27: the bounded carve
//       allowance — an expensive one-thread program (lifted off the quarter:
//       two readings over the band's tenth in a row) paces up to 4 x marked
//       (vgc_one_lift_pct), where the lift's GOGC=100 term held it to 1 x:
//       work 0 runs at most churn / (4 x live) x 1.25 + 8 collections (68;
//       the head's 1 x marked ran 163 on dev1, 2 x marked 96).
//   (e) the allowance is BOUNDED: no collection of work 0 paces past 4 x the
//       live set (+15 %) — not the band's cap, whose carve over a small live
//       set cx-home/v#14 bars.
//
// Run: ./v test bench/parallel-alloc/vgc_one_thread_cost_test.v
module main

import os

struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

const live_bytes = 4 * 1024 * 1024
const node_bytes = 48
const churn_mb = 768
const parent_work = 40
const heavy_work = 8000
const heavy_churn_mb = 16

fn child(work int, mb int) {
	mut head := &Node(unsafe { nil })
	for i in 0 .. live_bytes / node_bytes {
		mut n := &Node{
			next: head
		}
		n.pad[0] = u64(i)
		head = n
	}
	mut sink := u64(0)
	mut x := u64(1)
	for i in 0 .. i64(mb) * 1024 * 1024 / node_bytes {
		mut t := &Node{}
		t.pad[1] = u64(i)
		for _ in 0 .. work {
			x = x * 6364136223846793005 + 1442695040888963407
		}
		sink += (t.pad[1] ^ x) & 1
	}
	mut kept := 0
	for n := head; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('DONE sink=${sink} kept=${kept}')
}

struct Run {
	cycles   int
	mean_kb  u64
	tail_kb  u64
	marked_m u64
	max_kb   u64
}

fn run(work int, mb int, env string) Run {
	r := os.execute('VGC_ONE_COST_CHILD=${work} VGC_ONE_COST_MB=${mb} VGC_GCTRACE=1 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
	mut hs := []u64{}
	mut ms := []u64{}
	for l in r.output.split_into_lines() {
		if l.starts_with('[gc ') && l.contains(' headroom=') {
			hs << l.all_after(' headroom=').all_before('KB').u64()
			ms << l.all_after(' marked=').all_before('MB').u64()
		}
	}
	assert hs.len >= 4, 'too few collections (${hs.len}): ${r.output#[-400..]}'
	mut sum := u64(0)
	mut mx := u64(0)
	for h in hs {
		sum += h
		if h > mx {
			mx = h
		}
	}
	mut tail := u64(0)
	for h in hs#[hs.len - (hs.len + 3) / 4..] {
		if h > tail {
			tail = h
		}
	}
	return Run{
		cycles:   hs.len
		mean_kb:  sum / u64(hs.len)
		tail_kb:  tail
		marked_m: ms[ms.len - 1]
		max_kb:   mx
	}
}

fn test_a_costly_one_thread_mutator_is_not_held_to_the_quarter() {
	w := os.getenv('VGC_ONE_COST_CHILD')
	if w != '' {
		child(w.int(), os.getenv('VGC_ONE_COST_MB').int())
		return
	}
	env := os.getenv('VGC_ONE_COST_ENV')
	cheap := run(0, churn_mb, env)
	parent := run(parent_work, churn_mb, env)
	heavy := run(heavy_work, heavy_churn_mb, env)
	bound_a := 2 * churn_mb / (live_bytes / (1024 * 1024)) + 8
	bound_b := f64(parent.cycles) * 1.10 + 2
	term_kb := u64(live_bytes / 4 / 1024)
	bound_d := f64(churn_mb) / f64(4 * live_bytes / (1024 * 1024)) * 1.25 + 8
	bound_e := u64(f64(4 * live_bytes / 1024) * 1.15)
	println('vgc_one_thread_cost: work 0 ${cheap.cycles} cycles (mean headroom ${cheap.mean_kb} KB, last quarter max ${cheap.tail_kb} KB, marked ${cheap.marked_m} MB); work ${parent_work} ${parent.cycles} cycles (mean ${parent.mean_kb} KB); work ${heavy_work} ${heavy.cycles} cycles (last quarter max ${heavy.tail_kb} KB) (bars: (a) work 0 <= ${bound_a} cycles; (b) work 0 <= ${bound_b:.1f}; (c) work ${heavy_work} last quarter <= ${2 * term_kb} KB; (d) work 0 <= ${bound_d:.1f} cycles; (e) work 0 max headroom ${cheap.max_kb} KB <= ${bound_e} KB)')
	assert cheap.cycles <= bound_a, '(a) a mutator whose collections cost over a tenth of its time stayed at the quarter: ${cheap.cycles} cycles, mean headroom ${cheap.mean_kb} KB over a ${live_bytes / 1024} KB live set (bar ${bound_a})'
	assert f64(cheap.cycles) <= bound_b, '(b) the cheaper mutator ran ${cheap.cycles} collections against its parent\'s ${parent.cycles} on the same live set'
	assert heavy.tail_kb <= 2 * term_kb, '(c) a mutator whose collections are cheap left the quarter: ${heavy.tail_kb} KB (term ${term_kb} KB)'
	assert f64(cheap.cycles) <= bound_d, '(d) an expensive one-thread mutator did not take the bounded carve allowance (4 x marked; RULING 94-CARVE (b)): ${cheap.cycles} cycles, mean headroom ${cheap.mean_kb} KB over a ${live_bytes / 1024} KB live set (bar ${bound_d:.1f})'
	assert cheap.max_kb <= bound_e, '(e) the carve allowance is not bounded: a collection paced ${cheap.max_kb} KB of headroom over a ${live_bytes / 1024} KB live set (bar 4 x live + 15 %: ${bound_e} KB)'
}

// the lift's state machine (vgc_one_lift_next), white-box in module builtin
fn test_the_one_thread_lift_state() {
	if os.getenv('VGC_ONE_COST_CHILD') != '' {
		return
	}
	rc := vgc_one_lift_selftest()
	assert rc == 0, 'vgc_one_lift_selftest check ${rc}'
}
