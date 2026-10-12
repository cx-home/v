// vgc_cm_born_test.v — cx-private#1910 cut 1: the concurrent cycle's births.
//
// Every object born during the concurrent middle is marked by the alloc-black
// hook, so the termination count read the middle's allocation as live and the
// pacer doubled the goal on it (stw_scaling T=16: 152-392 MB marked against 82
// live, RSS 375 -> 447 MB; json-codec 24 against 19, 59.4 -> 71.7 MB). Now the
// cycle counts its births (`born=` on the VGC_GCTRACE=2 cm line), the pacer's
// marked set is the count less the births, and the middle stops once the births
// reach VGC_CM_BORN_PCT of the last live set (the rest of the mark runs under
// the termination stop), so a probe costs at most that much floating garbage.
//
// concurrent_born/born.v: main holds LIVE_MB of pointer-bearing records while
// THREADS workers allocate 1 KB records into rolling windows for OPS steps each,
// under VGC_CM=1 (every cycle concurrent).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_cm_born_test.v
module main

import os

const live_mb = 48

struct Cycle {
	marked_mb u64
	goal_mb   u64
	born_kb   u64
	cut       int
}

fn build_fixture() string {
	src := os.join_path(@DIR, 'concurrent_born', 'born.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_cm_born_${os.getpid()}')
	r := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn field(line string, key string) u64 {
	if !line.contains(key) {
		return 0
	}
	return line.all_after(key).all_before(' ').trim_right('MBKBus').u64()
}

// the concurrent cycles of one run: the [gc N] line paired with its cm line
fn run(exe string, env string) []Cycle {
	r := os.execute('${env} VGC_CM=1 VGC_GCTRACE=2 LIVE_MB=${live_mb} THREADS=8 OPS=400000 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains('live_nodes=${live_mb * 1024 * 1024 / 64} '), r.output
	mut out := []Cycle{}
	lines := r.output.split_into_lines()
	for i, line in lines {
		if !line.starts_with('[gc ') || !line.contains('] cm ') {
			continue
		}
		cyc := line.all_after('[gc ').all_before(']')
		mut gc_line := ''
		for j := i - 1; j >= 0 && j >= i - 4; j-- {
			if lines[j].starts_with('[gc ${cyc}] marked=') {
				gc_line = lines[j]
				break
			}
		}
		assert gc_line != '', 'no [gc ${cyc}] line before: ${line}'
		out << Cycle{
			marked_mb: field(gc_line, 'marked=')
			goal_mb:   field(gc_line, 'goal=')
			born_kb:   field(line, 'born=')
			cut:       int(field(line, 'cut='))
		}
	}
	assert out.len >= 3, 'fewer than 3 concurrent cycles: ${r.output}'
	return out
}

// Unbounded middles (VGC_CM_BORN_PCT=0): the births are counted and netted
// out — a cycle whose births reach the live set still paces on the live set.
fn test_births_are_netted_out_of_the_pacing_input() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	cycles := run(exe, 'VGC_CM_BORN_PCT=0')
	mut big := 0
	for c in cycles {
		// the chain is 48 MB; the windows and the runtime a few MB more
		assert c.marked_mb <= u64(live_mb) * 3 / 2, 'marked ${c.marked_mb} MB against ${live_mb} MB live (born ${c.born_kb} KB): ${cycles}'
		if c.born_kb >= u64(live_mb) * 1024 / 2 {
			big++
		}
	}
	assert big >= 1, 'no middle with births of half the live set: ${cycles}'
}

// The default bound (25 % of the live set) against the unbounded middles of
// the same fixture: a cut middle is reported, and the births of the bounded
// middles (their median over the churn) are at most half the unbounded ones'
// and within four times the bound — the overshoot past the bound is the
// stop's latency times the allocation rate, which a loaded 4-vCPU runner
// stretches, so the bar is relative, not the bound itself.
fn median(mut xs []u64) u64 {
	if xs.len == 0 {
		return 0
	}
	xs.sort()
	return xs[xs.len / 2]
}

fn test_the_middle_stops_at_the_born_bound() {
	exe := build_fixture()
	defer {
		os.rm(exe) or {}
	}
	unbounded := run(exe, 'VGC_CM_BORN_PCT=0')
	bounded := run(exe, '')
	bound_kb := u64(live_mb) * 1024 / 4
	mut ub := []u64{}
	for c in unbounded {
		if c.born_kb > 0 {
			ub << c.born_kb
		}
	}
	mut bb := []u64{}
	mut cuts := 0
	for c in bounded {
		assert c.marked_mb <= u64(live_mb) * 3 / 2, 'marked ${c.marked_mb} MB against ${live_mb} MB live: ${bounded}'
		if c.born_kb > 0 {
			bb << c.born_kb
		}
		cuts += c.cut
	}
	assert cuts >= 1, 'no cut middle under eight hot allocators: ${bounded}'
	um := median(mut ub)
	bm := median(mut bb)
	assert um > 0 && bm > 0, 'no births seen: unbounded ${unbounded}, bounded ${bounded}'
	assert bm * 2 <= um, 'bounded median born ${bm} KB is not half the unbounded ${um} KB: ${bounded}'
	assert bm <= bound_kb * 4, 'bounded median born ${bm} KB past four times the bound ${bound_kb} KB: ${bounded}'
}
