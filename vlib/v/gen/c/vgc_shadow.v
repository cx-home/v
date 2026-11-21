// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module c

import v.ast

// cx-home/v#74 piece 1, the shadow stack's compiler half (-gc e; piece 6: the
// default, -d vgc_byte_stack_scan turns it and the aligned-only scan off).
// The collector's aligned-only stack scan (piece 2) is sound only if no live
// reference sits at an unaligned stack offset. Those come from clang's SROA
// slices of V aggregates: SROA cuts a local at the edges of its typed accesses,
// and a field narrower than a word read on its own (an option's state byte, a
// struct's leading tag or int) leaves what follows it as one piece that starts
// off a word, copied by memcpy and kept in a byte array of alignment 1 — the
// references in that piece then sit at unaligned addresses (cx-home/v#60: a
// ?cx.Node's element pointer at sp+0x407).
// Every local whose type can be cut that way (vgc_ss_cuttable: a reference
// that follows a field narrower than a word) gets `vgc_ss_escape(&x)` right
// after its declaration (vgc_platform.h): a pointer-typed read of each word of
// x on a path that never runs. A pointer-typed read cannot be split, so every
// piece starts and ends on a word, and x stays in registers. A string, a
// dynamic array, a sum type, an interface without fields and a struct of
// references followed by small fields cannot be cut off a word and get nothing.

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
			cut, _ := g.vgc_ss_cuttable(typ, false, 0)
			g.vgc_ss_types[sym.cname] = cut
		}
	}
	g.vgc_ss_ntypes = n
}

fn (g &Gen) vgc_ss_is_ref_aggregate(ctype string) bool {
	if ctype.starts_with('_option_') || ctype.starts_with('_result_') {
		return true
	}
	// a map's references follow its int fields; a dynamic array's data pointer
	// is its first word, with ints behind it: it cannot be cut off a word
	if ctype.starts_with('Map_') {
		return true
	}
	return g.vgc_ss_types[ctype]
}

// vgc_ss_cuttable walks typ's leaves in layout order and answers whether a
// reference can land in a piece that starts off a word: true when a reference
// follows a leaf narrower than a word (`small`: such a leaf was passed already;
// the second answer is `small` after typ). Whatever it cannot place — an option
// or result (a state byte, then an IError), a map, a union, a C type, a
// reordered struct — is cuttable.
fn (mut g Gen) vgc_ss_cuttable(typ_ ast.Type, small bool, depth int) (bool, bool) {
	if depth > 24 || typ_.has_flag(.option) || typ_.has_flag(.result) {
		return true, true
	}
	typ := g.unwrap_generic(typ_)
	if typ.is_any_kind_of_pointer() || typ.is_ptr() || typ.has_flag(.shared_f)
		|| typ.has_flag(.atomic_f) {
		return small, small
	}
	sym := g.table.sym(typ)
	if sym.kind == .alias {
		return g.vgc_ss_cuttable((sym.info as ast.Alias).parent_type, small, depth + 1)
	}
	if sym.language != .v {
		return true, true
	}
	match sym.kind {
		.i64, .u64, .f64, .isize, .usize {
			return false, small
		}
		.i8, .i16, .i32, .int, .u8, .u16, .u32, .f32, .char, .rune, .bool, .enum {
			return false, true
		}
		.voidptr, .byteptr, .charptr, .chan, .thread, .function {
			return small, small
		}
		.string, .array {
			// the data pointer first, ints behind it
			return small, true
		}
		.sum_type {
			// a union of pointers, the u32 tag, then pointers to the common fields
			info := sym.info as ast.SumType
			return small || info.fields.len > 0, true
		}
		.interface {
			// the object pointer, the u32 tag, the method table (static, no
			// reference), then pointers to the interface's fields
			info := sym.info as ast.Interface
			return small || info.fields.len > 0, true
		}
		.array_fixed {
			info := sym.info as ast.ArrayFixed
			c1, s1 := g.vgc_ss_cuttable(info.elem_type, small, depth + 1)
			if c1 || info.size <= 1 {
				return c1, s1
			}
			return g.vgc_ss_cuttable(info.elem_type, s1, depth + 1)
		}
		.struct {
			info := sym.info as ast.Struct
			if info.is_union || info.is_minify || info.is_typedef {
				return true, true
			}
			mut sm := small
			for field in info.fields {
				c, s2 := g.vgc_ss_cuttable(field.typ, sm, depth + 1)
				if c {
					return true, true
				}
				sm = s2
			}
			return false, sm
		}
		.multi_return {
			info := sym.info as ast.MultiReturn
			mut sm := small
			for t in info.types {
				c, s2 := g.vgc_ss_cuttable(t, sm, depth + 1)
				if c {
					return true, true
				}
				sm = s2
			}
			return false, sm
		}
		else {
			return true, true
		}
	}
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
