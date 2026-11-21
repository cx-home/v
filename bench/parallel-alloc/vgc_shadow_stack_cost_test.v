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
// Shape: ss/kept.v built -prod. (1) spin(name string, rounds int) calls
// C.getpid and then reads name.len and a local string's len, every round: the
// test disassembles spin and counts single loads from its frame (arm64 ldr /
// ldur off sp or x29; x86-64 a mov whose source is off %rsp or %rbp); with the
// lengths in callee-saved registers there is none. (2) unwrap takes a struct
// with a leading byte out of an option ROUNDS times without allocating; four
// escaped locals a round. The program's instructions retired (/usr/bin/time
// -l), 4,000,000 rounds against 0, on this build against the -d
// vgc_byte_stack_scan build (no escape): at most 4 more a round — one an
// escape (arm64 pbm1: 82.2 with none; 96.2 with the address form, 90.2 with a
// read of every word, 84.2 with the reads behind a branch that is never taken).
// And cx itself: reading a word of ints as a pointer keeps that word in memory —
// the ten interpreted programs read +5 to +15 % instructions with every word
// read behind the branch (pbm1-guard74); and +10 an unwrap round with each
// reference read: both cut the local into more pieces than clang makes on its
// own. The pass reads the narrow field's word, which only moves clang's cut. macOS (otool, time -l); skipped elsewhere.
module main

import os

// fn_lines answers the disassembly lines of one function (its hot part: a
// `.cold.` part the compiler split off is another symbol)
fn fn_lines(exe string, name string) []string {
	r := os.execute('otool -tV ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	mut body := []string{}
	mut inside := false
	for line in r.output.split_into_lines() {
		if line == '_${name}:' {
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
	assert body.len > 4, 'no ${name} in the disassembly'
	return body
}

fn frame_loads(exe string) (int, string) {
	body := fn_lines(exe, 'main__spin')
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
	assert r.exit_code == 0 && r.output.contains('kept n=true acc=true'), r.output
	n, hits := frame_loads(exe)
	println('vgc_shadow_stack_cost: main__spin reads ${n} values back from its frame')
	assert n == 0, 'main__spin reads ${n} values back from its frame — the escape pass pinned its strings to memory:\n${hits}'
	i_esc := instr_a_round(exe)
	// the byte-scan build (no escape at all) is the reference: 0 there too
	b2 := os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -prod -d vgc_byte_stack_scan -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b2.exit_code == 0, b2.output
	n2, hits2 := frame_loads(exe)
	assert n2 == 0, 'the reference build reads ${n2} values back from the frame: the test has lost its shape\n${hits2}'
	i_ref := instr_a_round(exe)
	println('vgc_shadow_stack_cost: an unwrap round retires ${i_esc:.1f} instructions, ${i_ref:.1f} without the escapes')
	assert i_ref > 10.0, 'the reference round retires ${i_ref:.1f} instructions: the test has lost its shape'
	assert i_esc <= i_ref + 4.0, 'an unwrap round retires ${i_esc:.1f} instructions with its four escapes and ${i_ref:.1f} without: an escape must cost a branch, not a read of every word'
}

// instr_a_round answers the instructions the program retires for one round of
// unwrap: its count at 4,000,000 rounds less its count at 0, a round
fn instr_a_round(exe string) f64 {
	rounds := 4000000
	return (f64(instr(exe, rounds)) - f64(instr(exe, 0))) / f64(rounds)
}

fn instr(exe string, rounds int) u64 {
	r := os.execute('ROUNDS=${rounds} /usr/bin/time -l ${os.quoted_path(exe)} 2>&1')
	assert r.exit_code == 0, r.output
	for line in r.output.split_into_lines() {
		if line.contains('instructions retired') {
			return line.trim_space().all_before(' ').u64()
		}
	}
	assert false, 'no "instructions retired" line from /usr/bin/time -l:\n${r.output}'
	return 0
}
