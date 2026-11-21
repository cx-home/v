// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module c

import v.ast

// cx-home/v#74 piece 1, the shadow stack's compiler half (-gc e; piece 6: the
// default, -d vgc_byte_stack_scan turns it and the aligned-only scan off).
// The collector's aligned-only stack scan (piece 2) is sound only if no live
// reference sits at an unaligned stack offset. Those come from clang's SROA
// slices of V aggregates (an option's `u8 data[]` copy, a struct read through a
// leading byte). Clang cannot slice an aggregate whose address escapes, so
// every local of a reference-carrying aggregate type gets one escape right after
// its declaration: `vgc_ss_escape(&x)` = an empty asm that takes the address.
// The alloca is then captured: SROA leaves it whole, its bytes are current at
// every call, and its slot lives until its C scope ends. The intact, aligned
// copy is in the scanned stack for as long as V can use it. No push, no pop and
// no per-call work: those aggregates only lose registers.

// vgc_ss_on: the shadow stack's compiler half is in force for this build.
fn (g &Gen) vgc_ss_on() bool {
	return g.pref.gc_mode == .vgc && 'vgc_byte_stack_scan' !in g.pref.compile_defines
}

// vgc_ss_refresh fills vgc_ss_types from the table's symbols: every non-pointer
// aggregate (struct, sum type, interface, array, map, string, fixed array, alias
// of one) that carries a reference, by its C name. Options and results carry an
// IError always and are matched by prefix in vgc_ss_is_ref_aggregate.
fn (mut g Gen) vgc_ss_refresh() {
	n := g.table.type_symbols.len
	if n == g.vgc_ss_ntypes {
		return
	}
	for idx in g.vgc_ss_ntypes .. n {
		if idx == 0 {
			continue
		}
		sym := g.table.type_symbols[idx]
		if sym.kind !in [.struct, .sum_type, .interface, .array, .map, .string, .array_fixed, .alias,
			.multi_return] {
			continue
		}
		if sym.cname == '' {
			continue
		}
		typ := ast.idx_to_type(idx)
		if g.contains_ptr(typ) {
			g.vgc_ss_types[sym.cname] = true
		}
	}
	g.vgc_ss_ntypes = n
}

fn (g &Gen) vgc_ss_is_ref_aggregate(ctype string) bool {
	if ctype.starts_with('_option_') || ctype.starts_with('_result_') {
		return true
	}
	// a map and a dynamic array carry their data pointer whatever the element
	if ctype.starts_with('Map_')
		|| (ctype.starts_with('Array_') && !ctype.starts_with('Array_fixed_')) {
		return true
	}
	return ctype in g.vgc_ss_types
}

// vgc_ss_ident_end: the end of the C identifier that starts at i (i itself when none)
fn vgc_ss_ident_end(s string, i int) int {
	mut j := i
	for j < s.len && (s[j].is_letter() || s[j].is_digit() || s[j] == `_`) {
		j++
	}
	return j
}

// vgc_ss_depth_delta adds the line's (, {, [ minus its ), }, ] to depth, skipping
// string and character literals; it returns the new depth.
fn vgc_ss_depth_delta(line string, depth int) int {
	mut d := depth
	mut i := 0
	for i < line.len {
		c := line[i]
		if c == `"` || c == `'` {
			i++
			for i < line.len && line[i] != c {
				if line[i] == `\\` {
					i++
				}
				i++
			}
		} else if c == `/` && i + 1 < line.len && line[i + 1] == `/` {
			break
		} else if c == `(` || c == `{` || c == `[` {
			d++
		} else if c == `)` || c == `}` || c == `]` {
			d--
		}
		i++
	}
	return d
}

// vgc_ss_escapes rewrites a function body's C text: after every declaration
// `<tabs>T name;` or `<tabs>T name = ...;` (one line, or one statement over
// several lines) of a reference-carrying aggregate type T, it appends
// ` vgc_ss_escape(&name);`. `params` are the function's by-value aggregate
// parameters; they are escaped at the body's first line.
fn (mut g Gen) vgc_ss_escapes(body string, params []string) string {
	g.vgc_ss_refresh()
	lines := body.split('\n')
	mut out := []string{cap: lines.len + params.len}
	mut pending := ''
	mut depth := 0
	mut first := true
	for line in lines {
		if first && params.len > 0 {
			// the body text starts right after the function's opening `{`
			out << '\t' + params.map('vgc_ss_escape(&${it});').join(' ')
			first = false
		}
		first = false
		if pending != '' {
			depth = vgc_ss_depth_delta(line, depth)
			if depth <= 0 && line.trim_right(' \t').ends_with(';') {
				out << vgc_ss_append(line, pending)
				pending = ''
				depth = 0
			} else {
				out << line
			}
			continue
		}
		mut i := 0
		for i < line.len && (line[i] == `\t` || line[i] == ` `) {
			i++
		}
		if i == 0 {
			out << line
			continue
		}
		te := vgc_ss_ident_end(line, i)
		if te == i || te >= line.len || line[te] != ` ` {
			out << line
			continue
		}
		ctype := line[i..te]
		ns := te + 1
		ne := vgc_ss_ident_end(line, ns)
		if ne == ns || ne >= line.len || !g.vgc_ss_is_ref_aggregate(ctype) {
			out << line
			continue
		}
		name := line[ns..ne]
		rest := line[ne..]
		if rest == ';' || rest.starts_with('; /*') || rest.starts_with('; //') {
			out << vgc_ss_append(line, name)
			continue
		}
		if !rest.starts_with(' = ') {
			out << line
			continue
		}
		d := vgc_ss_depth_delta(rest, 0)
		if d == 0 && (rest.trim_right(' \t').ends_with(';') || rest.contains('; /*')) {
			out << vgc_ss_append(line, name)
		} else if d > 0 {
			pending = name
			depth = d
			out << line
		} else {
			out << line
		}
	}
	return out.join('\n')
}

// vgc_ss_append adds the escape after the declaration's statement: at the line's
// end, or before a trailing `//` comment (which would swallow it)
fn vgc_ss_append(line string, name string) string {
	esc := ' vgc_ss_escape(&${name});'
	if ci := line.last_index('; //') {
		return line[..ci + 1] + esc + line[ci + 1..]
	}
	return line + esc
}
