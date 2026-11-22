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
import strconv

fn build() string {
	src := os.join_path(@DIR, 'ua', 'planted.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_ua_planted_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -d vgc_unaligned_audit -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
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
		assert cycles >= 3, 'off ${off}: ${cycles} audited cycles'
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

// cx-home/v#74 piece 4: a `real` line is followed by the aligned stack word that
// reached the object in the judging cycle (its witness): kind=wit_old when that
// slot lay inside the range the previous cycle scanned, wit_new when below it
// (a deeper frame since), wit_heap when no aligned stack word names the object
// (a heap path). A planted reload names the aligned local the program read the
// word back into, with the same value.
fn test_a_real_line_names_its_aligned_witness() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		r := os.execute('VGC_CM=0 MODE=real OFF=${off} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, r.output
		lines := r.output.split_into_lines()
		reals := lines.filter(it.contains(' kind=real '))
		assert reals.len >= 1, r.output
		word := reals[0].all_after(' word=').all_before(' ')
		wits := lines.filter(it.contains(' kind=wit_'))
		assert wits.len >= 1, 'off ${off}: no witness line after the real line:\n${r.output}'
		assert wits.any(it.contains(' word=${word} ') && !it.contains('kind=wit_heap')), 'off ${off}: no aligned stack witness holds ${word}:\n${r.output}'
	}
}

// cx-home/v#74 piece 4: a word on another thread's stack is named by its frame
// too (pbm1-ss74c: 4 of arm64's 7 non-round real lines were on worker thread 7
// with frame=0x0 — the audit walked frame pointers on the collector's own stack
// only). A worker that keeps the buffer's only reference at an unaligned offset
// of its frame, blocked in a channel pop while main collects, is named
// frame=main__worker_holds.
fn test_a_worker_threads_unaligned_word_is_named_by_its_frame() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		r := os.execute('VGC_CM=0 MODE=thread OFF=${off} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, r.output
		lines := r.output.split_into_lines().filter(it.contains(' kind=only ')
			&& !it.contains(' thread=0 '))
		assert lines.len >= 1, 'off ${off}: no unaligned-only line on the worker:\n${r.output}'
		assert lines.any(it.ends_with(' frame=main__worker_holds')), 'off ${off}: the worker\'s frame is not named:\n${r.output}'
	}
}

// cx-home/v#74 piece 4 (x86-wit74b's first witness: the object a real line named
// was reached in the judging cycle through a different, interior word in a live
// frame): an object named only by a stale unaligned word, then FREED by the
// program (an eager free) and its slot handed to a new allocation the program
// holds, is a new object — the audit must not call the old word real
fn test_a_freed_and_reused_slot_is_not_counted_real() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		r := os.execute('VGC_CM=0 MODE=freed OFF=${off} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, r.output
		lines := r.output.split_into_lines().filter(it.starts_with('ua only='))
		assert lines.len == 1, r.output
		d := lines[0]
		assert d.contains('sevens=1'), 'off ${off}: no 200-byte allocation reused the freed slot (${d})'
		assert d.all_after('only=').all_before(' ').int() >= 1, 'off ${off}: ${d}'
		real := d.all_after('real=').all_before(' ').int()
		assert real == 0, 'off ${off}: a freed slot reused by a new object was counted real ${real} times:\n${r.output}'
	}
}

// cx-home/v#74 piece 4: a word that is two small 32-bit integers side by side
// (high half under 256, low half within +-64 K as a signed int) is its own
// class, `pair`, counted real_pair apart from real. On x86-64 the heap starts
// at 4 GB, so (lo, 1) and (lo, 2) land in it: x86-wit74b's real lines on
// 0x1ffffffff had ALIGNED witnesses holding the same 0x1ffffffff — the integer
// pair (-1, 1) in an aligned slot, not a reloaded pointer; 0x200000100 /
// 0x200000204 are (0x100, 2) / (0x204, 2). The round class (low 24 bits 0 or
// 1) stays as it was; a word with a real address shape stays `pointer`.
fn test_the_audit_classes_small_integer_pairs_apart() {
	src := os.join_path(@DIR, 'ua', 'classify.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_ua_classify_${os.getpid()}')
	b := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -d vgc_unaligned_audit -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b.exit_code == 0, b.output
	defer {
		os.rm(exe) or {}
	}
	want := {
		'0x1ffffffff':  'pair'
		'0x200000100':  'pair'
		'0x200000204':  'pair'
		'0x7000000070': 'pair'
		'0x1fffffe00':  'pair'
		'0x7000000001': 'round'
		'0x220000000':  'round'
		'0x16ef24101':  'pointer'
		'0x1ff228320':  'pointer'
		'0x11fffe500':  'pointer'
		'0x1481f0000':  'pointer'
	}
	mut args := []string{}
	for k, _ in want {
		args << (strconv.parse_uint(k[2..], 16, 64) or { 0 }).str()
	}
	r := os.execute('${os.quoted_path(exe)} ${args.join(' ')}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines()
	mut i := 0
	for k, v in want {
		assert lines[i].all_after(' ') == v, '${k}: ${lines[i]} (want ${v})'
		i++
	}
}

// cx-home/v#74 piece 4 (x86-wit74d, pbm1-ss74d): an aligned word that names a
// remembered object again is not a reload. x86-wit74d's 81,788,936-byte buffer
// was named by one unaligned integer for 385 cycles after the program dropped
// it and was called real 5 times: stale exact-base words in unwritten slots of
// new collect_frames frames, then a plain integer (0x1a17f070f) inside it — and
// the 33 objects it points to were called real with it in one cycle (wit_heap).
// MODE=stale holds the planted word's VALUE in an aligned integer local across
// the judging cycle and never uses it. Under VGC_UA_POISON=1 the unaligned-only
// object is filled with a pattern when it is found; only a write to it or its
// free is `real`. The stale word is `only`, poisoned, and not real.
fn test_under_the_poison_an_aligned_word_that_only_names_the_object_is_not_real() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		r := os.execute('VGC_CM=0 VGC_UA_POISON=1 MODE=stale OFF=${off} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, r.output
		lines := r.output.split_into_lines().filter(it.starts_with('ua only='))
		assert lines.len == 1, r.output
		d := lines[0]
		println('vgc_unaligned_audit poison stale off=${off}: ${d}')
		assert d.all_after('only=').all_before(' ').int() >= 1, 'off ${off}: ${d}'
		assert d.all_after('poison=').all_before(' ').int() >= 1, 'off ${off}: the unaligned-only buffer was not poisoned (${d})'
		real := d.all_after('real=').all_before(' ').int()
		assert real == 0, 'off ${off}: a word that only names the dropped buffer was counted real ${real} times:\n${r.output}'
	}
}

// ... and the program that really holds the buffer only at an unaligned offset
// is caught twice over: it reads the pattern (no seven is left — its own checks
// fail), and its write to the buffer is the real verdict, with a wit_write line
// naming the byte.
fn test_under_the_poison_a_real_unaligned_root_reads_the_pattern_and_its_write_is_real() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		r := os.execute('VGC_CM=0 VGC_UA_POISON=1 MODE=real OFF=${off} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, r.output
		lines := r.output.split_into_lines().filter(it.starts_with('ua only='))
		assert lines.len == 1, r.output
		d := lines[0]
		println('vgc_unaligned_audit poison real off=${off}: ${d}')
		assert d.all_after('real=').all_before(' ').int() >= 1, 'off ${off}: the written buffer was not counted real:\n${r.output}'
		assert d.all_after('sevens=').all_before(' ').int() == 0, 'off ${off}: the holder did not read the pattern (${d})'
		assert r.output.contains(' kind=wit_write '), 'off ${off}: no wit_write line:\n${r.output}'
	}
}

// ... and a free of a poisoned object is a use too (the program held it).
fn test_under_the_poison_a_free_of_an_unaligned_only_object_is_real() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		r := os.execute('VGC_CM=0 VGC_UA_POISON=1 MODE=freed OFF=${off} ${os.quoted_path(exe)}')
		assert r.exit_code == 0, r.output
		d := r.output.split_into_lines().filter(it.starts_with('ua only='))[0]
		assert d.all_after('real=').all_before(' ').int() >= 1, 'off ${off}: the freed poisoned buffer was not counted real:\n${r.output}'
		assert r.output.contains(' kind=wit_free '), 'off ${off}: no wit_free line:\n${r.output}'
	}
}

// cx-home/v#74 piece 4 (pbm1-ss74d's hang, 33 minutes): the audit named a
// worker's frame with dladdr while the world was stopped, and a thread the stop
// suspended inside dlopen held dyld's loaders lock. A line written under the
// stop now waits and is named after the world restarts: the count of dladdr
// calls under the stop is 0, and the worker's frame is still named.
fn test_the_audit_asks_dyld_for_no_name_while_the_world_is_stopped() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_CM=0 MODE=thread OFF=3 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	assert r.output.contains('ua thread done dl=0'), r.output
	assert r.output.split_into_lines().any(it.contains(' kind=only ') && it.ends_with(' frame=main__worker_holds')), r.output
}
