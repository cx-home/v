// vgc_unaligned_audit_test.v — -d vgc_unaligned_audit counts the stack's real
// unaligned roots (cx-home/v#74, the operator's option (c): measure whether
// clang ever keeps a live pointer only at an unaligned stack offset on our
// builds, before the byte-offset scan of cx-home/v#60 is narrowed to aligned
// words). In the audit build a stop-the-world full cycle marks from every
// root but the stack's unaligned words first, then shades the deferred
// unaligned words one by one: a word that marks something no aligned root
// reached is an unaligned-only root (`only`, the upper bound: real and false
// alike). Its object is remembered; a later cycle whose aligned roots reach
// the same allocation counts it `real` — the program held a live reference
// there, then loaded it back. A dropped object named by a stale unaligned word
// never comes back, so a false word is `only` and never `real`.
// Shape: ua/planted.v (MODE=real / MODE=false), offsets 1, 3, 7.
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'ua', 'planted.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_ua_planted_${os.getpid()}')
	r := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -d vgc_unaligned_audit -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn run(exe string, mode string, off int) (int, int, int, int) {
	r := os.execute('VGC_CM=0 MODE=${mode} OFF=${off} ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines().filter(it.starts_with('ua only='))
	assert lines.len == 1, r.output
	d := lines[0]
	println('vgc_unaligned_audit ${mode} off=${off}: ${d}')
	return d.all_after('only=').all_before(' ').int(), d.all_after('real=').all_before(' ').int(), d.all_after('cycles=').all_before(' ').int(), d.all_after('sevens=').all_before(' ').int()
}

fn test_a_planted_unaligned_real_root_is_counted_real() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		only, real, cycles, sevens := run(exe, 'real', off)
		assert cycles >= 4, 'off ${off}: ${cycles} audited cycles'
		assert only >= 1, 'off ${off}: the buffer held only at an unaligned offset was not counted unaligned-only (${only})'
		assert real >= 1, 'off ${off}: the buffer read back into an aligned local was not counted real (${real})'
		assert sevens == 64 * 1024, 'off ${off}: the buffer read ${sevens} sevens: the audit build must keep what the byte scan keeps'
	}
}

fn test_a_planted_unaligned_false_word_is_not_counted_real() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		only, real, _, _ := run(exe, 'false', off)
		assert only >= 1, 'off ${off}: the stale unaligned word was not counted unaligned-only (${only})'
		assert real == 0, 'off ${off}: a word naming an object nothing reads again was counted real ${real} times'
	}
}
