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
// Every local whose type can be cut that way gets, right after its declaration,
// `vgc_ss_ref(x, <offset>)` for each word of x that holds a field narrower than
// a word with a reference somewhere behind it (vgc_ss_walk; vgc_platform.h): a
// pointer-typed read of that whole word, on a path that never runs. A
// pointer-typed read cannot be split, so the cut the narrow field makes moves to
// the end of its word: what follows starts on a word, as large a piece as
// before, and x stays in registers. (Reading every word, or each reference,
// cuts x into more pieces than clang makes on its own, and every move of x then
// costs more: pbm1-guard74 read +5 to +15 % instructions on cx that way.)
// A string, a dynamic array, a sum type, an interface without fields and a
// struct of references followed by small fields cannot be cut off a word and get
// nothing; a map, a union, a C struct and anything the walk cannot place get
// `vgc_ss_pin(&x)`, the address under a memory clobber (x then stays whole in
// its slot, at the price of its registers).

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
			g.vgc_ss_sym[sym.cname] = idx
		}
	}
	g.vgc_ss_ntypes = n
}

// vgc_ss_is_ref_aggregate: a local of C type ctype gets an escape
fn (mut g Gen) vgc_ss_is_ref_aggregate(ctype string) bool {
	return g.vgc_ss_refs_of(ctype).len > 0
}

// vgc_ss_refs_of answers what to read of a local of C type ctype: the byte
// offsets (C constant expressions) of its words that hold a narrow field with a
// reference behind it, `&` alone for the address form, nothing for a type that
// cannot be cut off a word
fn (mut g Gen) vgc_ss_refs_of(ctype string) []string {
	if r := g.vgc_ss_refs[ctype] {
		return r
	}
	mut refs := []string{}
	mut typ := ast.Type(0)
	if t := g.vgc_ss_opt[ctype] {
		typ = t
	} else if idx := g.vgc_ss_sym[ctype] {
		typ = ast.idx_to_type(idx)
	} else if ctype.starts_with('_option_') || ctype.starts_with('_result_')
		|| ctype.starts_with('Map_') {
		refs << '&'
	}
	if typ != 0 {
		mut pend := []string{}
		if !g.vgc_ss_walk(typ, ctype, '0', 0, mut pend, mut refs) {
			refs = ['&']
		}
	}
	g.vgc_ss_refs[ctype] = refs
	return refs
}

// vgc_ss_text: the escape statement(s) for the local `name` of C type ctype
fn (mut g Gen) vgc_ss_text(ctype string, name string) string {
	refs := g.vgc_ss_refs_of(ctype)
	if refs.len == 1 && refs[0] == '&' {
		return ' vgc_ss_pin(&${name});'
	}
	mut out := ''
	for r in refs {
		out += ' vgc_ss_ref(${name}, ${r});'
	}
	return out
}

// vgc_ss_small notes a leaf narrower than a word at offset `at`
fn vgc_ss_small(at string, mut pend []string) {
	if pend.len == 0 || pend.last() != at {
		pend << at
	}
}

// vgc_ss_refleaf: a reference at this point of the walk — every narrow field
// passed since the last one can cut it off a word: their words are read
fn vgc_ss_refleaf(mut pend []string, mut refs []string) {
	for p in pend {
		if p !in refs {
			refs << p
		}
	}
	pend.clear()
}

// vgc_ss_walk walks typ's leaves in layout order; `at` is the byte offset of
// the value walked in the local (a C constant expression) and `cname` its C
// type. A leaf narrower than a word goes to `pend`; a reference moves what is
// pending to `refs`. False for what the walk cannot place — a map, a union, a
// C type, a reordered struct, a long fixed array: the caller pins the local.
fn (mut g Gen) vgc_ss_walk(typ_ ast.Type, cname string, at string, depth int, mut pend []string, mut refs []string) bool {
	if depth > 24 || refs.len > 24 {
		return false
	}
	if typ_.has_flag(.option) || typ_.has_flag(.result) {
		// { u8 state; IError err; u8 data[sizeof(T)]; } — IError: the object
		// pointer, a u32 tag, the method table
		vgc_ss_small(at, mut pend)
		vgc_ss_refleaf(mut pend, mut refs)
		vgc_ss_small('${at} + __builtin_offsetof(${cname}, err) + 8', mut pend)
		base := typ_.clear_option_and_result()
		if base.idx() == ast.void_type_idx || base.idx() == ast.none_type_idx || base.idx() == 0 {
			return true
		}
		return g.vgc_ss_walk(base, g.styp(base), '${at} + __builtin_offsetof(${cname}, data)',
			depth + 1, mut pend, mut refs)
	}
	typ := g.unwrap_generic(typ_)
	if typ.is_any_kind_of_pointer() || typ.is_ptr() || typ.has_flag(.shared_f)
		|| typ.has_flag(.atomic_f) {
		vgc_ss_refleaf(mut pend, mut refs)
		return true
	}
	sym := g.table.sym(typ)
	if sym.kind == .alias {
		parent := (sym.info as ast.Alias).parent_type
		return g.vgc_ss_walk(parent, g.styp(parent), at, depth + 1, mut pend, mut refs)
	}
	if sym.language != .v {
		return false
	}
	match sym.kind {
		.i64, .u64, .f64, .isize, .usize, .function {
			// a whole word that is no reference
			return true
		}
		.i8, .i16, .i32, .int, .u8, .u16, .u32, .f32, .char, .rune, .bool, .enum {
			vgc_ss_small(at, mut pend)
			return true
		}
		.voidptr, .byteptr, .charptr, .chan, .thread {
			vgc_ss_refleaf(mut pend, mut refs)
			return true
		}
		.string {
			// { u8* str; int len; int is_lit; }
			vgc_ss_refleaf(mut pend, mut refs)
			vgc_ss_small('${at} + 8', mut pend)
			return true
		}
		.array {
			// { void* data; int offset; int len; int cap; flags; int element_size; }
			vgc_ss_refleaf(mut pend, mut refs)
			vgc_ss_small('${at} + 8', mut pend)
			vgc_ss_small('${at} + 16', mut pend)
			vgc_ss_small('${at} + 24', mut pend)
			return true
		}
		.sum_type, .interface {
			// a union of pointers (the object pointer), the u32 tag, (the method
			// table: static, no reference,) then pointers to the common fields
			vgc_ss_refleaf(mut pend, mut refs)
			vgc_ss_small('${at} + 8', mut pend)
			nfields := if sym.info is ast.SumType {
				sym.info.fields.len
			} else if sym.info is ast.Interface {
				sym.info.fields.len
			} else {
				0
			}
			if nfields > 0 {
				vgc_ss_refleaf(mut pend, mut refs)
			}
			return true
		}
		.array_fixed {
			info := sym.info as ast.ArrayFixed
			if info.size > 8 || info.size < 0 {
				return false
			}
			ecname := g.styp(info.elem_type)
			for i in 0 .. info.size {
				if !g.vgc_ss_walk(info.elem_type, ecname, '${at} + ${i} * sizeof(${ecname})',
					depth + 1, mut pend, mut refs) {
					return false
				}
			}
			return true
		}
		.struct {
			info := sym.info as ast.Struct
			if info.is_union || info.is_minify || info.is_typedef {
				return false
			}
			for field in info.fields {
				fcname := g.styp(field.typ)
				if !g.vgc_ss_walk(field.typ, fcname, '${at} + __builtin_offsetof(${cname}, ${c_name(field.name)})',
					depth + 1, mut pend, mut refs) {
					return false
				}
			}
			return true
		}
		.multi_return {
			info := sym.info as ast.MultiReturn
			for i, t in info.types {
				if !g.vgc_ss_walk(t, g.styp(t), '${at} + __builtin_offsetof(${cname}, arg${i})',
					depth + 1, mut pend, mut refs) {
					return false
				}
			}
			return true
		}
		else {
			return false
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
// several lines) of a type T that can be cut off a word, it appends T's escape
// for name (vgc_ss_text). `params` are the escapes of the function's by-value
// parameters; they go to the body's first line.
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
			out << '\t' + params.map(it.trim_left(' ')).join(' ')
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
		name := g.vgc_ss_text(ctype, line[ns..ne])
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
		} else if d >= 0 {
			// the statement goes on over the next lines (an open bracket, or a
			// call whose `;` is on a line of its own)
			pending = name
			depth = d
			out << line
		} else {
			out << line
		}
	}
	return out.join('\n')
}

// vgc_ss_append adds the escape text after the declaration's statement: at the
// line's end, or before a trailing `//` comment (which would swallow it)
fn vgc_ss_append(line string, esc string) string {
	if ci := line.last_index('; //') {
		return line[..ci + 1] + esc + line[ci + 1..]
	}
	return line + esc
}
