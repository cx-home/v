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

// build allocates the shape (cx-home/v#51): its loop runs in its own frame, so
// the loop's temporaries (array structs, element pointers, a node literal) die
// with it. Run in child()'s frame, a dead temporary of that loop is a stack
// slot the collector scans conservatively at every later collection: CI
// 39126681128 (the test x400 under -d vgc_rootdiag) named it, a word 2080
// bytes below main__child's frame pointer (tcc) holding an arena's base, which
// is the address of the 1 KB buffer carved first in that arena — kept by the
// program's own stale slot, not by the walk, in whichever run it happened to
// hold one. The span count is the walk mode's only when no such slot is live.
@[noinline]
fn build(mut kept []&Node, key u64) u64 {
	mut sink := u64(0)
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
	return sink
}

// churn allocates and drops 16 MB of 1 KB buffers, in its own frame as build
@[noinline]
fn churn() u64 {
	mut sink := u64(0)
	for i in 0 .. 16384 {
		t := []u8{len: 1024, init: u8(i)}
		sink += u64(t[i % 1024])
	}
	return sink
}

// Before each collection the dead stack under child() is overwritten with
// integers (plant_scrub, 32 KB): build()'s and churn()'s returned frames then
// hold no address when gc_collect's frames are laid over them.
fn child() {
	mut kept := []&Node{cap: node_count / 3 + 1}
	mut sink := u64(0)
	mut key := u64(0)
	if os.getenv('VGC_PS_PLANT') == '1' {
		key = plant_alloc_and_drop()
		sink += plant_scrub() & 1
	}
	sink += build(mut kept, key)
	sink += plant_scrub() & 1
	for _ in 0 .. 3 {
		gc_collect()
	}
	// drop every other kept node: more recycle and relink verdicts next cycle
	for k in 0 .. kept.len {
		if k % 2 == 1 {
			kept[k] = unsafe { nil }
		}
	}
	sink += plant_scrub() & 1
	gc_collect()
	gc_collect()
	sink += churn()
	sink += plant_scrub() & 1
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
	// cx-home/v#51: the in-use spans by object size, for a mismatch to name
	// the span one run holds over the other
	println('CENSUS=${vgc_span_census()}')
	// cx-home/v#51: every allocated 1 KB buffer no kept node owns, and each word
	// that holds its address (the 1152-byte class is where the extra span sat:
	// CI 39035166177's census 1152:0/1641/0 against 1152:0/1640/0)
	mut known := []usize{cap: kept.len}
	for n in kept {
		if n != unsafe { nil } && n.id % 4 == 0 {
			known << usize(n.buf.data)
		}
	}
	println('HOLDERS=${vgc_orphan_holders(known, 1152)}')
	// cx-home/v#51 (diag): where the cache records sit, so a -d vgc_rootdiag
	// line of kind caches names its slot and field
	println('CACHES=${vgc_cache_layout()}')
	$if linux {
		exe := os.executable()
		maps := os.read_file('/proc/self/maps') or { '' }
		for l in maps.split_into_lines() {
			if l.ends_with(exe) {
				println('BASE=0x${l.all_before('-')}')
				break
			}
		}
	}
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

// cx-home/v#51: one run's per-cycle span counts and walker counts, and its
// census, for the mismatch message
fn evidence(out string) string {
	mut cyc := []string{}
	mut census := ''
	mut holders := ''
	mut base := u64(0)
	mut caches := ''
	mut rd := []string{}
	for l in out.split_into_lines() {
		if l.contains(' phases ') && l.contains('spans_in_use=') {
			cyc << '${l.all_after('spans_in_use=').all_before(' ')}/w${l.all_after('walkers=').all_before(' ')}'
		}
		if l.starts_with('CENSUS=') {
			census = l.all_after('CENSUS=')
		}
		if l.starts_with('HOLDERS=') {
			holders = l.all_after('HOLDERS=')
		}
		if l.starts_with('BASE=') {
			base = l.all_after('BASE=0x').parse_uint(16, 64) or { 0 }
		}
		if l.starts_with('CACHES=') {
			caches = l.all_after('CACHES=')
		}
		if l.starts_with('[rootdiag gc ') {
			rd << l
		}
	}
	return 'cycles ${cyc.join(' ')}; census ${census}; holders ${holders}${data_symbols(holders,
		base)}${last_cycle_roots(rd, base)}; caches ${caches}'
}

// cx-home/v#51 (diag, a -d vgc_rootdiag build): the last cycle's root words that
// alone reached less than 1 MB (the kept list's root reaches the whole live
// set), each with its kind, address and value, and a data word's symbol
fn last_cycle_roots(rd []string, base u64) string {
	if rd.len == 0 {
		return ''
	}
	last := rd.last().all_after('[rootdiag gc ').all_before(']')
	mut out := []string{}
	mut data := []string{}
	for l in rd {
		if l.all_after('[rootdiag gc ').all_before(']') != last {
			continue
		}
		if l.all_after('reaches=').all_before(' ').u64() >= 1048576 {
			continue
		}
		if out.len < 40 {
			out << l.all_after('] ')
		}
		if l.contains('root=data') {
			data << 'rd-data@${l.all_after('where=').all_before(' ')}='
		}
		if l.contains(' frame=0x') {
			data << 'rd-frame@${l.all_after(' frame=').all_before(' ')}='
		}
	}
	return '; rootdiag gc ${last}: ${out.join(' | ')}${data_symbols(data.join(','), base)}'
}

// data_symbols names the symbol of each data-segment holder (Linux: the child's
// load base from /proc/self/maps and `nm -n` of this binary), for the message
fn data_symbols(holders string, base u64) string {
	if base == 0 || !(holders.contains('data') || holders.contains('rd-frame')) {
		return ''
	}
	r := os.execute('nm -n ${os.quoted_path(os.executable())}')
	if r.exit_code != 0 {
		return ''
	}
	mut addrs := []u64{}
	mut names := []string{}
	for l in r.output.split_into_lines() {
		f := l.fields()
		if f.len == 3 {
			addrs << f[0].parse_uint(16, 64) or { continue }
			names << f[2]
		}
	}
	mut out := []string{}
	for e in holders.split(',') {
		if !(e.contains('data') || e.contains('rd-frame')) || !e.contains('@0x') {
			continue
		}
		// a PIE binary's symbols are offsets from the load base; a fixed one's are addresses
		abs := e.all_after('@0x').all_before('=').parse_uint(16, 64) or { continue }
		a := if addrs.len > 0 && addrs.last() >= base { abs } else { abs - base }
		mut best := -1
		for i, x in addrs {
			if x <= a {
				best = i
			}
		}
		if best >= 0 {
			out << '${e.all_before('@')}=${names[best]}+${a - addrs[best]}'
		}
	}
	return if out.len == 0 { '' } else { ' [${out.join(' ')}]' }
}

// cx-home/v#44: the span count is the walk mode's alone only while no scanned
// word aliases the heap. Forced: the same one-walker run with one planted
// address reads exactly one span more, and the same checksum.
fn test_an_integer_word_aliasing_a_dead_span_keeps_it() {
	if os.getenv('VGC_PS_CHILD') != '' {
		return
	}
	one, out1 := run('VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=1 ')
	planted, outp := run('VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=1 VGC_PS_PLANT=1 ')
	println('vgc_parallel_sweep: one walker ${one}; planted ${planted}')
	assert one.all_before(' ') == planted.all_before(' '), 'the plant changed the live data: ${one} against ${planted}'
	n_one := one.all_after('spans_in_use=').int()
	n_planted := planted.all_after('spans_in_use=').int()
	assert n_planted == n_one + 1, 'a word holding a dropped buffer address keeps exactly its span: ${n_one} against ${n_planted}\none walker: ${evidence(out1)}\nplanted: ${evidence(outp)}'
}

fn test_parallel_walks_leave_the_heap_as_the_serial_walks_do() {
	if os.getenv('VGC_PS_CHILD') != '' {
		child()
		return
	}
	one, out1 := run('VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=1 ')
	par, out :=
		run('VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=8 VGC_WALK_PAR_MIN_SPANS=64 VGC_WALK_LOAD_GATE=0 ')
	println('vgc_parallel_sweep: one walker ${one}; eight walkers ${par}')
	assert one == par, 'the parallel walks left a different heap: ${one} against ${par}\none walker: ${evidence(out1)}\neight walkers: ${evidence(out)}'
	assert out.contains('walkers=8'), 'the walks did not engage (no walkers=8 phase line):\n${out}'
	assert out.contains('markers=1'), 'expected one marker (the walks plan on their own):\n${out}'
}
