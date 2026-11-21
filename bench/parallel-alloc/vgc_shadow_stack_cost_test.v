// vgc_shadow_stack_cost_test.v — the escape pass keeps a reference-carrying
// local out of unaligned stack bytes WITHOUT pinning it to memory (cx-home/v#74
// piece 5).
//
// The first shape of vgc_ss_escape took the local's address under a "memory"
// clobber. That is sound, and it costs what a captured local costs: the local
// lives in the frame and is read back after every call. pbm1-ab74i read the ten
// Benchmarks Game programs interpreted on that build at +18 to +30 %
// instructions against the pinned V (spectral-norm 6.64e9 against 5.13e9) and
// `cx --version` at 6,608 KB against 6,304.
//
// What the pass needs is narrower: no piece SROA makes of the local may start
// off a word. A pointer-typed read of each 8-byte word (an empty asm taking the
// VALUE) does that, takes no address, and leaves the local in registers.
//
// Shape: ss/kept.v built -prod; spin(name string, rounds int) calls C.getpid
// and then reads name.len and a local string's len, every round. The test
// disassembles spin and counts single loads from its frame (arm64 ldr / ldur
// off sp or x29; x86-64 a mov whose source is off %rsp or %rbp). With the
// lengths in callee-saved registers there is none. macOS (otool); skipped
// elsewhere.
module main

import os

fn frame_loads(exe string) (int, string) {
	r := os.execute('otool -tV ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	mut body := []string{}
	mut inside := false
	for line in r.output.split_into_lines() {
		if line.starts_with('_main__spin:') {
			inside = true
			continue
		}
		if inside {
			if line.len > 0 && line[0] == `_` && line.ends_with(':') {
				break
			}
			body << line
		}
	}
	assert body.len > 4, 'no main__spin in the disassembly'
	mut n := 0
	mut hits := []string{}
	for line in body {
		l := line.replace('\t', ' ')
		arm := (l.contains(' ldr ') || l.contains(' ldur ')) && (l.contains('[sp') || l.contains('[x29'))
		x86 := l.contains(' mov') && (l.contains('(%rsp),') || l.contains('(%rbp),'))
		if arm || x86 {
			n++
			hits << line.trim_space()
		}
	}
	return n, hits.join('\n')
}

fn test_a_string_held_across_calls_is_not_read_back_from_the_frame() {
	$if !macos {
		eprintln('skipped: the disassembly read is macOS otool')
		return
	}
	src := os.join_path(@DIR, 'ss', 'kept.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_ss_kept_${os.getpid()}')
	b := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -prod -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b.exit_code == 0, b.output
	defer {
		os.rm(exe) or {}
	}
	r := os.execute(os.quoted_path(exe))
	assert r.exit_code == 0 && r.output.contains('kept n=true'), r.output
	n, hits := frame_loads(exe)
	println('vgc_shadow_stack_cost: main__spin reads ${n} values back from its frame')
	assert n == 0, 'main__spin reads ${n} values back from its frame — the escape pass pinned its strings to memory:\n${hits}'
	// the byte-scan build (no escape at all) is the reference: 0 there too
	b2 := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -prod -d vgc_byte_stack_scan -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b2.exit_code == 0, b2.output
	n2, hits2 := frame_loads(exe)
	assert n2 == 0, 'the reference build reads ${n2} values back from the frame: the test has lost its shape\n${hits2}'
}
