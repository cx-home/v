// DIAG ONLY (cx-home/v#44) — never land. Runs vgc_parallel_sweep_test's child
// N times per mode and prints spans_in_use beside the number of live nodes
// whose integer words (tag, pad[25]) fall inside the address range the
// child's own allocations occupy. TOPBIT=1 sets bit 63 on every tag.
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

const node_count = 24 * 1024 * 1024 / 1280
const mask = u64(0xa5a5000000000000)

fn child() {
	hi_bit := if os.getenv('PS_TOPBIT') == '1' { u64(1) << 63 } else { u64(0) }
	mut kept := []&Node{cap: node_count / 3 + 1}
	mut sink := u64(0)
	mut lo := u64(0xffffffffffffffff) ^ mask
	mut hi := u64(0) ^ mask
	for i in 0 .. node_count {
		mut n := &Node{
			id:  u64(i)
			tag: (u64(i) * 2654435761 + 97) | hi_bit
		}
		a := u64(voidptr(n))
		if a < (lo ^ mask) {
			lo = a ^ mask
		}
		if a > (hi ^ mask) {
			hi = a ^ mask
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
	l := lo ^ mask
	h := (hi ^ mask) + 64 * 1024 * 1024
	mut hits := 0
	for n in kept {
		if n == unsafe { nil } {
			continue
		}
		if n.tag >= l && n.tag < h {
			hits++
		}
		if n.pad[25] >= l && n.pad[25] < h {
			hits++
		}
	}
	println('HITS=${hits} lo=0x${l.hex()} hi=0x${h.hex()} sink=${sink}')
}

fn one(env string) string {
	r := os.execute('VGC_PS_CHILD=1 VGC_GCTRACE=2 VGC_NEXT_GC_MB=512 ${env}${os.quoted_path(os.executable())}')
	mut spans := ''
	mut hits := ''
	for l in r.output.split_into_lines() {
		if l.starts_with('HITS=') {
			hits = l
		}
		if l.contains(' phases ') && l.contains('spans_in_use=') {
			spans = l.all_after('spans_in_use=').all_before(' ')
		}
	}
	return 'exit=${r.exit_code} spans_in_use=${spans} ${hits}'
}

fn test_diag() {
	if os.getenv('VGC_PS_CHILD') != '' {
		child()
		return
	}
	for tb in ['0', '1'] {
		for w in ['VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=1 ', 'VGC_MARK_WORKERS=1 VGC_WALK_WORKERS=8 VGC_WALK_PAR_MIN_SPANS=64 VGC_WALK_LOAD_GATE=0 '] {
			for k in 0 .. 15 {
				println('DIAG topbit=${tb} walkers=${if w.contains('=8') { 8 } else { 1 }} run=${k} ${one('PS_TOPBIT=${tb} ' + w)}')
			}
		}
	}
	assert false, 'DIAG END (forced fail so the output prints)'
}
