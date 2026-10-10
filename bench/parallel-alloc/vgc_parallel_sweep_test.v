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

fn child() {
	mut kept := []&Node{cap: node_count / 3 + 1}
	mut sink := u64(0)
	for i in 0 .. node_count {
		mut n := &Node{
			id:  u64(i)
			tag: u64(i) * 2654435761 + 97
		}
		if i % 4 == 0 {
			n.buf = []u8{len: 1024, init: u8(i)}
		} else {
			b := []u8{len: 1024, init: u8(i)}
			sink += u64(b[i % 1024])
		}
		n.pad[25] = n.tag ^ n.id
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
		if n.tag != n.id * 2654435761 + 97 || n.pad[25] != (n.tag ^ n.id) {
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

fn run(env string) (string, string) {
	r :=
		os.execute('VGC_PS_CHILD=1 VGC_GCTRACE=2 VGC_NEXT_GC_MB=512 ${env}${os.quoted_path(os.executable())}')
	assert r.exit_code == 0, r.output
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
	assert check != '', r.output
	assert spans != '', r.output
	return '${check} spans_in_use=${spans}', r.output
}

fn test_parallel_walks_leave_the_heap_as_the_serial_walks_do() {
	if os.getenv('VGC_PS_CHILD') != '' {
		child()
		return
	}
	one, _ := run('VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=1 ')
	par, out :=
		run('VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=8 VGC_WALK_PAR_MIN_SPANS=64 VGC_WALK_LOAD_GATE=0 ')
	println('vgc_parallel_sweep: one walker ${one}; eight walkers ${par}')
	assert one == par, 'the parallel walks left a different heap: ${one} against ${par}'
	assert out.contains('walkers=8'), 'the walks did not engage (no walkers=8 phase line):\n${out}'
	assert out.contains('markers=1'), 'expected one marker (the walks plan on their own):\n${out}'
}
