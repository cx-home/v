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
// vgc_byte_stack_scan build (no escape): at most 2 more a round (arm64 pbm1:
// 82.2 with none; 96.2 with each local's address taken, 90.2 with every word
// read as a pointer, 84.2-86.0 with fewer words read, behind a branch or not,
// 85.2 with one byte read — and 83.1 with that byte only asked about).
// cx itself decides (ten interpreted programs, instructions retired against
// the pinned V): every shape that uses the local for real where it is declared
// read +13 to +30 % at worst. macOS (otool, time -l); skipped elsewhere.
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
		arm := (l.contains(' ldr ') || l.contains(' ldur '))
			&& (l.contains('[sp') || l.contains('[x29'))
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
	b :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -prod -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
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
	b2 :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -prod -d vgc_byte_stack_scan -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b2.exit_code == 0, b2.output
	n2, hits2 := frame_loads(exe)
	assert n2 == 0, 'the reference build reads ${n2} values back from the frame: the test has lost its shape\n${hits2}'
	i_ref := instr_a_round(exe)
	println('vgc_shadow_stack_cost: an unwrap round retires ${i_esc:.1f} instructions, ${i_ref:.1f} without the escapes')
	assert i_ref > 10.0, 'the reference round retires ${i_ref:.1f} instructions: the test has lost its shape'
	assert i_esc <= i_ref + 2.0, 'an unwrap round retires ${i_esc:.1f} instructions with its four escapes and ${i_ref:.1f} without: an escape must cost nothing where the local is declared'
}

// An escape must also cost nothing to the passes that run before its question
// is answered. ss/chain.v: six option unwraps of a struct with a leading byte in
// one function, each read by field (twelve escaped locals, eighteen escapes). With the escape a
// branch around an empty asm (c02a90108f) the round retired 147.0 instructions
// against 106.2 without escapes on arm64 pbm1: the
// inliner charged a load, a branch and a call for each, and the asm was a call
// that may write memory to every pass until the question was lowered. cx read
// that as cx__mk_scalar, code__is_err_value and 1,200 other call sites no
// longer inlined, n-body 1.092. The round may cost 2 % more than the build
// without escapes, the bar the interpreted programs are held to.
fn test_an_unwrap_chain_costs_no_more_than_without_its_escapes() {
	$if !macos {
		eprintln('skipped: instructions retired are read from macOS time -l')
		return
	}
	src := os.join_path(@DIR, 'ss', 'chain.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_ss_chain_${os.getpid()}')
	b :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -prod -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b.exit_code == 0, b.output
	defer {
		os.rm(exe) or {}
	}
	r := os.execute(os.quoted_path(exe))
	assert r.exit_code == 0 && r.output.contains('chain acc=true'), r.output
	i_esc := instr_a_round(exe)
	b2 :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -prod -d vgc_byte_stack_scan -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert b2.exit_code == 0, b2.output
	i_ref := instr_a_round(exe)
	println('vgc_shadow_stack_cost: a chain round retires ${i_esc:.1f} instructions, ${i_ref:.1f} without the escapes')
	assert i_ref > 50.0, 'the reference round retires ${i_ref:.1f} instructions: the test has lost its shape'
	assert i_esc <= i_ref * 1.02, 'a chain round retires ${i_esc:.1f} instructions with its escapes and ${i_ref:.1f} without: more than 2 % over'
}

// A by-value parameter's escape must not lift the function's inline cost: the
// interpreter's small methods on cx.Node (a by-value receiver) are folded into
// hundreds of callers, and clang's threshold is a handful of points above
// their cost (cx.Node.scalar_value: 220 against 225). An escape at the
// function's entry that reads the receiver's first word costs five points —
// the receiver's tag byte, read later at the same address, is counted a
// second time — and the method is called out of line from every caller
// (1,192 call sites against 107, k-nucleotide 6 % over the pinned V; kn15–18,
// 11-22). ss/method.v is that shape; the cost is read from clang's own inline
// remark, with and without the escapes.
fn test_a_by_value_receivers_escape_costs_the_method_no_inline_cost() {
	if os.user_os() != 'macos' {
		eprintln('skipped: the disassembly read is macOS otool')
		return
	}
	exe := os.join_path(os.vtmp_dir(), 'vgc_ss_method_${os.getpid()}')
	defer { os.rm(exe) or {} }
	cost_esc, out_esc := build_method(exe, '')
	r := os.execute('otool -tV ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	bl := r.output.split_into_lines().filter(it.contains('\tbl\t')
		&& it.ends_with('_main__Node_value'))
	cost_ref, out_ref := build_method(exe + '_ref', '-d vgc_byte_stack_scan')
	os.rm(exe + '_ref') or {}
	println('vgc_shadow_stack_cost: clang inlines main__Node_value at cost ${cost_esc} with the escapes, ${cost_ref} without')
	assert cost_ref > 0, 'no inline remark for main__Node_value without the escapes:\n${out_ref}'
	assert cost_esc > 0, 'no inline remark for main__Node_value with the escapes:\n${out_esc}'
	assert cost_esc == cost_ref, 'the escapes lift main__Node_value\'s inline cost from ${cost_ref} to ${cost_esc}: an escape on a by-value parameter must cost the inliner nothing'
	assert bl.len == 0, 'main__Node_value is called out of line at ${bl.len} sites:\n${bl.join('\n')}'
}

// build_method builds ss/method.v -prod with flags and answers clang's inline
// cost of main__Node_value at its first call site (0 when no remark names it)
// and the compiler's output
fn build_method(exe string, flags string) (int, string) {
	src := os.join_path(os.dir(@FILE), 'ss', 'method.v')
	cmd := '${os.quoted_path(@VEXE)} -prod -gc e ${flags} -show-c-output -cflags "-Rpass=inline -Rpass-missed=inline" -o ${os.quoted_path(exe)} ${os.quoted_path(src)}'
	r := os.execute(cmd)
	assert r.exit_code == 0, '${cmd}\n${r.output}'
	for line in r.output.split_into_lines() {
		if !line.contains("'main__Node_value'") || !line.contains('cost=') {
			continue
		}
		return line.all_after('cost=').all_before(',').int(), r.output
	}
	return 0, r.output
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
