// vgc_grow_gate_growing_test.v — on a heap whose live set keeps growing, the
// VGCG-1 grow gate adds no collections (cx-private batch I-1, Letter 190).
//
// The gate defers an arena carve to one collection when the heap has grown
// vgc_grow_gate_pct of the way from the last marked set to the goal. That
// pays when the collection finds garbage the growth can reuse. While the live
// set still grows, the collection marks a set that is mostly live, and the
// trigger recompute after it shortens the next cycle. `cx fmt` of an
// 8k-record document took 15 collections instead of 10, +15 % wall time
// (perf-ratchet tooling.fmt_8k_ms 1304 -> 1506 ms on 169397f61).
//
// Shape: a live set that grows to 384 MB in 2 KB records, each record built
// beside one 2 KB transient, the way a formatter keeps its output and drops
// its scratch. The child runs the build with the gate at its default and with
// it off (VGC_GROW_GATE_PCT=0), three times each, the two arms interleaved
// (off, on, off, on, ...) so both see the same load. The child notes the
// record at which each collection completed (gc_cycles), and both arms are
// counted up to the same point of the run: the last record at which a gate-off
// run collected. The gate at its default must take no more collections up to
// that point than the most the gate-off arm took, and its total pause time
// (VGC_GCTRACE, the least of its runs) no more than 1.25x the gate off's least
// plus 10 ms.
//
// Why up to the same point, not the whole run (cx-home/v#59, owner ruling V59
// (a)): the whole-run count also reads where the run happens to end. The
// one-thread pacing (cx-home/v#56) steps the first cycles at 1.5x, so every
// later cycle lands at another heap position, and a credited probe late in the
// run moves the cycle that ends it: at 224 MB live the gate-on arm's last
// goal fell just under the end of the run where the gate-off arm's fell just
// past it, one collection more (14/15) that the gate did not add on the
// growing heap. A collection past the gate-off arm's last one is a cycle the
// gate-off arm never reached, not one the gate cost.
//
// Why 384 MB: counted up to the gate-off arm's last collection, the gate's
// regression shows only where that collection falls late in the run. Swept on
// dev2 (cx-home/v#59, gate off / default / VGC_GROW_GATE_GROWTH_PCT=100, up to
// that point): 128-288 MB read one count in all three arms (15 or 14), the
// regression's extra probe landing past the point; 320 MB and 384 MB read
// 14/14/15, at 384 MB the point at record 170947 of 196608 (x3 alike).
//
// Why the gate-off arm's MOST, not its least: the pacer is adaptive, and a
// loaded box can take a collection AWAY as well as add one — a stretched
// pause reads as GC overhead, the headroom doubles a cycle earlier, and the
// run ends one collection short (CI ubuntu/FreeBSD and dev2 at load 220-310:
// gate off 9,10,10,9,10,9 against default 10 every run; cx-home/v#16). The
// gate's own regression is a collection beyond the whole off range: with the
// growing guard defeated (run the test with VGC_GROW_GATE_GROWTH_PCT=100:
// the children inherit it) the gate probes every growing cycle, the shape
// takes more collections before the gate-off arm's last one than that arm
// took, and the test is red.
//
// The pause bound is wall time, so it is judged only when the runner is not
// oversubscribed: the one-minute load average at the start and at the end of
// the six runs at most the CPU count. On FreeBSD's 4-vCPU CI runner with four
// test binaries in parallel (the markers-forced suite) the least of three
// gate-on pause sums read 974 ms against the gate-off arm's 550 with the same
// collection counts (vgc 38204997509 twice, 38229128715), and green in the
// serial and default modes of the same runs — the load stretched the pauses,
// not the gate. A loaded run still judges the collection count, which is the
// gate's own regression; cx-private's perf-pair leaves time rows unjudged on a
// loaded box the same way (cx-private#1450).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_grow_gate_growing_test.v
module main

import os
import runtime

fn C.getloadavg(loadavg &f64, nelem int) int

// load1 is the one-minute load average, or -1 where getloadavg answers nothing
// (and on Windows, which has none: the bound is judged there as before).
fn load1() f64 {
	$if windows {
		return -1
	} $else {
		mut la := [3]f64{}
		if C.getloadavg(&la[0], 1) != 1 {
			return -1
		}
		return la[0]
	}
}

const rec = 2048
const live_bytes = 384 * 1024 * 1024

// grow builds the live set and answers, per collection completed during the
// build, the record it completed at (a record that saw two collections is
// listed twice): the point of the run each collection belongs to, the same
// in both arms whatever heap position the pacing puts it at.
fn grow() []int {
	mut keep := [][]u8{cap: live_bytes / rec}
	mut at := []int{cap: 64}
	mut seen := gc_cycles()
	mut sink := 0
	for i in 0 .. live_bytes / rec {
		scratch := []u8{len: rec, init: u8(i)}
		mut r := []u8{len: rec}
		r[0] = scratch[i % rec]
		sink += r[0]
		keep << r
		now := gc_cycles()
		for seen < now {
			at << i
			seen++
		}
	}
	// never true: it keeps the live set and the sink read past the build
	if keep.len + sink % 2 == 0 {
		at << -1
	}
	return at
}

struct Trace {
	at       []int // the record each collection of the build completed at
	pause_us u64
}

// upto counts the collections of a run up to and at record `last`.
fn (t Trace) upto(last int) int {
	return t.at.filter(it <= last).len
}

// last is the record of the run's last collection, -1 with none.
fn (t Trace) last() int {
	return if t.at.len == 0 { -1 } else { t.at.last() }
}

fn run_child(pct string) Trace {
	env := if pct == '' { '' } else { 'VGC_GROW_GATE_PCT=${pct} ' }
	r := os.execute('VGC_GROW_CHILD=1 VGC_GCTRACE=1 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, 'the child failed (${pct}): ${r.output}'
	mut pause := u64(0)
	mut at := []int{}
	mut done := false
	for line in r.output.split_into_lines() {
		if line.starts_with('GROW-AT=') {
			done = true
			list := line.all_after('GROW-AT=')
			if list != '' {
				at = list.split(',').map(it.int())
			}
		} else if line.starts_with('[gc ') && line.contains('pause=') {
			pause += line.all_after('pause=').all_before('us').u64()
		}
	}
	assert done, 'the child printed no GROW-AT line: ${r.output}'
	assert -1 !in at
	return Trace{
		at:       at
		pause_us: pause
	}
}

fn test_a_growing_heap_takes_no_extra_collections() {
	if os.getenv('VGC_GROW_CHILD') != '' {
		println('GROW-AT=' + grow().map(it.str()).join(','))
		return
	}
	load_start := load1()
	mut offs := []Trace{}
	mut ons := []Trace{}
	for _ in 0 .. 3 {
		offs << run_child('0')
		ons << run_child('')
	}
	// the same point of the run for both arms: the last record at which a
	// gate-off run collected (the latest of the three)
	mut last := -1
	for o in offs {
		last = if o.last() > last { o.last() } else { last }
	}
	assert last >= 0, 'the gate-off arm collected nothing while the heap grew'
	off_counts := offs.map(it.upto(last))
	on_counts := ons.map(it.upto(last))
	mut off_least := off_counts[0]
	mut off_most := off_counts[0]
	mut on_least := on_counts[0]
	for i in 1 .. 3 {
		off_least = if off_counts[i] < off_least { off_counts[i] } else { off_least }
		off_most = if off_counts[i] > off_most { off_counts[i] } else { off_most }
		on_least = if on_counts[i] < on_least { on_counts[i] } else { on_least }
	}
	mut off_pause := offs[0].pause_us
	mut on_pause := ons[0].pause_us
	for i in 1 .. 3 {
		off_pause = if offs[i].pause_us < off_pause { offs[i].pause_us } else { off_pause }
		on_pause = if ons[i].pause_us < on_pause { ons[i].pause_us } else { on_pause }
	}
	println('vgc_grow_gate_growing: up to record ${last} of ${live_bytes / rec}: gate off ${off_least}-${off_most} collections ${off_pause} us; default ${on_least} collections ${on_pause} us (whole build: off ${offs.map(it.at.len)}, default ${ons.map(it.at.len)})')
	assert on_least <= off_most, 'the gate added collections on a growing heap: ${on_least} against ${off_least}-${off_most} with the gate off, up to record ${last} (default ${ons.map(it.at)}; off ${offs.map(it.at)})'
	load_end := load1()
	ncpu := f64(runtime.nr_cpus())
	if load_start > ncpu || load_end > ncpu {
		println('vgc_grow_gate_growing: pause bound not judged: load ${load_start:.1f} -> ${load_end:.1f} on ${ncpu} CPUs (wall time on an oversubscribed runner)')
		return
	}
	assert on_pause <= off_pause * 5 / 4 + 10000, 'the gate added pause time on a growing heap: ${on_pause} us against ${off_pause} us (load ${load_start:.1f} -> ${load_end:.1f} on ${ncpu} CPUs)'
}
