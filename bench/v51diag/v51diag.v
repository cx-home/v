// vgc_parallel_sweep_test.v — the span walks (clear, count, the sweep's bit
// work) on the marker pool leave the heap exactly as the one-thread walks do,
// and the pool's lists are never touched inside the walk (cx-home/v#16).
//
// The rule under test: a walker touches only the span it sweeps and writes its
// verdict into vgc_walk_tag; the collector applies the verdicts in slot order
// after the join. vgc_put_free_span, vgc_pool_defrag and the central relink
// abort (0x3a1c / 0x3a1d / 0x3a1e) if they run while the walk is active, so a
// walk that touched a list is a crash, not a silent reorder.
//
// Shape: the main thread alone (a deterministic allocation sequence) builds
// 24 MB of 256-byte scan nodes and 1 KB noscan buffers — with the goal
// pinned at 512 MB (VGC_NEXT_GC_MB), so no automatic cycle runs and every
// collection below is an explicit one: the same allocation sequence, the same
// spans, the same verdicts, run after run — keeping every third node and every fourth
// buffer, so the span table holds thousands of spans that are partly live
// (relink verdicts), fully dead (recycle verdicts) and full. Then: three
// collections; half the kept nodes dropped and two more collections; 16 MB of
// churn and a last collection. The child prints a checksum over every
// surviving node's payload and buffer byte, and the last phase line's
// spans_in_use. The one-walker run (VGC_WALK_WORKERS=1) and the eight-walker
// run (VGC_WALK_WORKERS=8 VGC_WALK_PAR_MIN_SPANS=64 VGC_WALK_LOAD_GATE=0: the
// mechanism is under test, not the load gate; one marker both times) must
// print the same line, both must exit 0, and the parallel run's phase lines
// must say walkers=8.
//
// Run: ./v test bench/parallel-alloc/vgc_parallel_sweep_test.v
module main

import os

@[heap]
struct Node {
mut:
	id  u64
	tag u64
	buf []u8
	pad [26]u64
}

const node_count = 24 * 1024 * 1024 / 1280 // ~19.6k rounds of one node + one buffer

// Bit 63 on every tag (cx-home/v#44): the collector scans a node's words
// conservatively, so a tag (i * 2654435761 + 97 spans 0 .. 5.2e13) that falls
// inside the arenas retains whatever span it points into. Where the arenas
// sit moves per process under ASLR (FreeBSD), so the one-walker and the
// eight-walker runs could each retain a different extra span: 2301 against
// 2302 on CI 38492110432. A word with bit 63 set is no user-space address on
// any target, so no tag or pad word aliases the heap and the span count is
// the walk mode's alone.
const tag_hi = u64(1) << 63

fn tag_of(id u64) u64 {
	return (id * 2654435761 + 97) | tag_hi
}

// The forced alias (VGC_PS_PLANT=1): a dropped 64 KB buffer's address is
// written into kept node 0's pad[0] as plain integer data — what a tag did by
// chance on FreeBSD. The collector scans that word conservatively, so the
// buffer's span stays in use: the plant run reads exactly one span more than
// the same run without it. The address crosses the stack only masked.
const plant_mask = u64(0x5a5a000000000000)
const plant_big = 64 * 1024

@[noinline]
fn plant_alloc_and_drop() u64 {
	mut b := []u8{len: plant_big}
	for i := 0; i < plant_big; i += 4096 {
		b[i] = 1
	}
	return u64(voidptr(unsafe { &b[0] })) ^ plant_mask
}

@[noinline]
fn plant_scrub() u64 {
	mut buf := [4096]u64{}
	for i in 0 .. buf.len {
		buf[i] = u64(i)
	}
	return buf[4095]
}

fn child() {
	mut kept := []&Node{cap: node_count / 3 + 1}
	mut sink := u64(0)
	mut key := u64(0)
	if os.getenv('VGC_PS_PLANT') == '1' {
		key = plant_alloc_and_drop()
		sink += plant_scrub() & 1
	}
	for i in 0 .. node_count {
		mut n := &Node{
			id:  u64(i)
			tag: tag_of(u64(i))
		}
		if i % 4 == 0 {
			n.buf = []u8{len: 1024, init: u8(i)}
		} else {
			b := []u8{len: 1024, init: u8(i)}
			sink += u64(b[i % 1024])
		}
		n.pad[25] = n.tag ^ n.id
		if i == 0 && key != 0 {
			n.pad[0] = key ^ plant_mask
		}
		if i % 3 == 0 {
			kept << n
		} else {
			sink += n.tag & 0xff
		}
	}
	for _ in 0 .. 3 {
		gc_collect()
	}
	// drop every other kept node: more recycle and relink verdicts next cycle
	for k in 0 .. kept.len {
		if k % 2 == 1 {
			kept[k] = unsafe { nil }
		}
	}
	gc_collect()
	gc_collect()
	for i in 0 .. 16384 {
		t := []u8{len: 1024, init: u8(i)}
		sink += u64(t[i % 1024])
	}
	gc_collect()
	mut sum := u64(0)
	mut live := u64(0)
	for n in kept {
		if n == unsafe { nil } {
			continue
		}
		if n.tag != tag_of(n.id) || n.pad[25] != (n.tag ^ n.id) {
			println('BAD node ${n.id}')
			exit(3)
		}
		if n.id % 4 == 0 {
			if n.buf.len != 1024 || n.buf[0] != u8(n.id) || n.buf[1023] != u8(n.id) {
				println('BAD buf ${n.id}')
				exit(3)
			}
			sum += u64(n.buf[512])
		}
		sum += n.tag
		live++
	}
	println('CHECK=${sum}:${live} sink=${sink} cycles=${gc_cycles()}')
}

// cx-home/v#51 diagnostic (not a test): runs the one-walker and the eight-walker child
// N times each (VGC_V51_N, default 20) with VGC_ROOTDIAG_MIN_KB=0 under a -d vgc_rootdiag
// build, compares the lines, and on a mismatch prints both runs' root reports (kind,
// offset, bytes, objects; addresses dropped: they move per process) side by side.
fn run_one(env string) (string, string) {
	r := os.execute('VGC_PS_CHILD=1 VGC_GCTRACE=2 VGC_NEXT_GC_MB=512 VGC_ROOTDIAG_MIN_KB=0 ${env}${os.quoted_path(os.executable())} 2>&1')
	mut check := ''
	mut spans := ''
	for l in r.output.split_into_lines() {
		if l.starts_with('CHECK=') {
			check = l.all_after('CHECK=').all_before(' ')
		}
		if l.contains(' phases ') && l.contains('spans_in_use=') {
			spans = l.all_after('spans_in_use=').all_before(' ')
		}
	}
	return '${check} spans_in_use=${spans} rc=${r.exit_code}', r.output
}

fn main() {
	if os.getenv('VGC_PS_CHILD') != '' {
		child()
		return
	}
	n := if os.getenv('VGC_V51_N') != '' { os.getenv('VGC_V51_N').int() } else { 20 }
	mut bad := 0
	for i in 0 .. n {
		one, o1 := run_one('VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=1 ')
		par, o8 := run_one('VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=8 VGC_WALK_PAR_MIN_SPANS=64 VGC_WALK_LOAD_GATE=0 ')
		println('v51 round ${i}: one ${one}; eight ${par}')
		if one != par {
			bad++
			println('==== MISMATCH round ${i}: one-walker output (rootdiag lines) ====')
			for l in o1.split_into_lines() {
				if !l.starts_with('CHECK=') && !l.contains(' phases ') {
					println('ONE ${l}')
				}
			}
			println('==== eight-walker output (rootdiag lines) ====')
			for l in o8.split_into_lines() {
				if !l.starts_with('CHECK=') && !l.contains(' phases ') {
					println('PAR ${l}')
				}
			}
		}
	}
	println('v51: ${bad} of ${n} rounds mismatched')
}
