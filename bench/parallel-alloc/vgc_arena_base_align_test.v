// vgc_arena_base_align_test.v — every arena's base is a multiple of
// vgc_page_size (cx-home/cx-core-code#282).
//
// The collector's cards (the write barrier's dirty bits, the inline gate,
// vgc_cards_take, the permanent generation's page bits) are indexed by the
// ABSOLUTE address >> 13, while a span sits at arena.base + k * 8 KB. darwin
// arm64's mmap hands out 16 KB-aligned addresses, so every logical page is one
// card; darwin x86-64's (and Linux's) mmap is only 4 KB-aligned — ardec-dev3
// gave every 64 MB arena a base 4096 mod 8192, 12 of 12 — so the upper half of
// each logical page lies under the NEXT page's card, which vgc_cards_take(span)
// never reads for that span: a pointer a permanent object holds there is never
// re-scanned and the young object it names is swept (the interpreter then read
// variable names that were other strings).
//
// The child carves arenas the plain way and under VGC_TEST_ARENA_HINT at an
// address 4096 mod 8192 (the hook's arenas; the first arena, carved in _vinit
// before the env is read, the plain way in both), allocates past three arenas
// plus one oversized arena, and prints every arena base; the parent asserts
// each is page-aligned.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_arena_base_align_test.v
module main

import os

const page = usize(8192)

fn align_main() {
	mut keep := [][]u8{}
	for _ in 0 .. 12 {
		mut b := []u8{len: 16 * 1024 * 1024}
		b[b.len - 1] = 1
		keep << b
	}
	mut big := []u8{len: 80 * 1024 * 1024}
	big[big.len - 1] = 7
	keep << big
	mut n := 0
	mut odd := 0
	mut bases := []string{}
	for i in 0 .. 4096 {
		b := vgc_arena_base_probe(i)
		if b == 0 {
			break
		}
		n++
		if b % page != 0 {
			odd++
		}
		bases << '0x${u64(b).hex()}'
	}
	println('ALIGN arenas=${n} odd=${odd} kept=${keep.len} bases=${bases.join(',')}')
}

fn check(name string, env map[string]string) {
	mut cmd := ''
	for k, v in env {
		cmd += '${k}=${v} '
	}
	r := os.execute('${cmd}VGC_ABA_CHILD=1 ${os.quoted_path(os.executable())}')
	println('vgc_arena_base_align ${name}: exit=${r.exit_code}: ${r.output.trim_space()}')
	assert r.exit_code == 0, r.output
	line := r.output.split_into_lines().filter(it.starts_with('ALIGN '))
	assert line.len == 1, r.output
	w := line[0].split(' ')
	assert w[1].starts_with('arenas=') && w[1].all_after('=').int() >= 3, line[0]
	assert w[2] == 'odd=0', 'an arena base is not a multiple of ${page}: ${line[0]}'
}

fn test_arena_bases_page_aligned() {
	if os.getenv('VGC_ABA_CHILD') != '' {
		align_main()
		return
	}
	check('plain mmap', map[string]string{})
	// 0x300001000: 4096 mod 8192, as darwin x86-64's mmap hands out
	check('hint 4 KB-odd', {
		'VGC_TEST_ARENA_HINT': '0x300001000'
	})
}
