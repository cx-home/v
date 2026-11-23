// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module c

import os
import v.ast

// PROBE (cx-home/v#74 experiment 2, 11-22; VGC_SS_PARAMREAD=1): a by-value
// parameter's escape is dropped where the body names the member that holds the
// cut (`n.u.` for cx.Node's union word): the function then has a typed access
// at the cut itself. An UPPER BOUND on what the rule can gain — a narrow member
// of a union (n.u.b, a bool) also matches; the sound rule reads the access's
// width.
const vgc_ss_paramread = os.getenv('VGC_SS_PARAMREAD') != ''

// vgc_ss_param_unread answers the escape statements of esc whose cut's first
// member the body does not name on pname ('' when none is left)
fn vgc_ss_param_unread(esc string, pname string, body string) string {
	mut out := []string{}
	for st in esc.split(';') {
		t := st.trim_space()
		if t == '' {
			continue
		}
		mut keep := true
		if i := t.index('__builtin_offsetof(') {
			rest := t[i + '__builtin_offsetof('.len..]
			m := rest.all_after(', ').all_before(')')
			key := '${pname}.${m}'
			mut k := 0
			for {
				j := body.index_after(key, k) or { break }
				e := j + key.len
				if e < body.len && body[e] in [`.`, `)`, `,`, `;`, ` `, `-`, `[`] {
					keep = false
					break
				}
				k = e
			}
		}
		if keep {
			out << t + ';'
		}
	}
	return out.join(' ')
}

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
// `vgc_ss_ref(x, <offset of a reference>)` for the first reference of x behind
// each run of narrow fields (vgc_ss_walk; vgc_platform.h): the half word or the
// word that ends where that reference starts, as the operand of
// __builtin_constant_p. To SROA that is a float or a double read, which cannot
// be split: a cut falls on the word where the reference starts, so the piece
// that holds the reference starts on a word. To the machine it is nothing — the
// question is answered late, after the passes that cut locals. The read covers
// the last narrow field before the reference (a string's is_lit, a kind byte
// and the padding behind it, a state byte's word): that field and its padding
// become one piece, as when the function reads the field itself, and no piece
// of padding is left to copy on its own (a ONE-byte read left one: pbm1-ab74ks,
// +16 % on n-body from the locals read by field alone). x stays in registers,
// and nothing has to be computed where x is declared. (Every shape with a real use of x at its
// declaration cost cx 13 to 30 %: pbm1-ab74k / ab74z / ab74u / ab74c.)
// A string, a dynamic array, a sum type, an interface without fields and a
// struct of references followed by small fields cannot be cut off a word and get
// nothing; a C struct, a packed or reordered struct and a long fixed array of
// references get `vgc_ss_pin(&x)`, the address under a memory clobber (x then
// stays whole in its slot, at the price of its registers).

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

// VgcSsLeaf: one leaf of a local's type — its byte offset in the local (as the
// compiler lays it out, and as a C constant expression) and whether it is a
// reference or a field narrower than a word
struct VgcSsLeaf {
	off    int
	is_ref bool
	expr   string
}

// vgc_ss_refs_of answers where to cut a local of C type ctype: for each
// reference that is the first one behind a field narrower than a word,
// `<its C offset expression>, <its offset>`; `&` alone for the address form;
// nothing for a type that cannot be cut off a word.
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
		mut leaves := []VgcSsLeaf{}
		if g.vgc_ss_walk(typ, ctype, 0, '0', 0, mut leaves) {
			// in layout order (a narrow field before a reference at the same
			// offset: a union's members): the first reference behind a narrow
			// field gets the cut, and what follows it is on a word again until
			// the next narrow field
			leaves.sort_with_compare(fn (a &VgcSsLeaf, b &VgcSsLeaf) int {
				if a.off != b.off {
					return a.off - b.off
				}
				return int(a.is_ref) - int(b.is_ref)
			})
			mut dirty := false
			mut cuts := []int{}
			mut last_small := -1
			for l in leaves {
				if !l.is_ref {
					dirty = true
					last_small = l.off
				} else if dirty {
					dirty = false
					if l.off >= 8 && l.off !in cuts && l.expr != '' {
						cuts << l.off
						// the read ends at the reference and covers the last narrow
						// field before it: the upper half of the word when that field
						// starts there (a string's is_lit, a kind byte at +4), else the
						// whole word (a state byte, an array's element_size)
						n := if last_small >= l.off - 4 { 4 } else { 8 }
						refs << '${n}(@, ${l.expr}, ${l.off})'
					} else if l.expr == '' {
						refs = ['&']
						break
					}
				}
			}
			if refs.len > 16 {
				refs = ['&']
			}
		} else {
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
		out += ' vgc_ss_ref${r.replace('@', name)};'
	}
	return out
}

// vgc_ss_size: the C size and alignment of a value of type typ, as cgen lays it
// out. The table's type_size is not that: it answers 4 for every enum (one
// declared `as u8` is a byte) and the error's size for an option or a result
// ({ u8 state; IError err; u8 data[sizeof(T)]; }). 0, 0 for what it cannot lay
// out (a packed or reordered struct, a C type).
fn (mut g Gen) vgc_ss_size(typ_ ast.Type) (int, int) {
	if typ_.has_flag(.option) || typ_.has_flag(.result) {
		base := typ_.clear_option_and_result()
		mut bs := 1
		if base.idx() != ast.void_type_idx && base.idx() != ast.none_type_idx && base.idx() != 0 {
			b, ba := g.vgc_ss_size(base)
			if ba <= 0 {
				return 0, 0
			}
			if b > bs {
				bs = b
			}
		}
		return 32 + (bs + 7) / 8 * 8, 8
	}
	typ := g.unwrap_generic(typ_)
	if typ.is_any_kind_of_pointer() || typ.is_ptr() || typ.has_flag(.shared_f)
		|| typ.has_flag(.atomic_f) {
		return 8, 8
	}
	sym := g.table.sym(typ)
	match sym.kind {
		.alias {
			return g.vgc_ss_size((sym.info as ast.Alias).parent_type)
		}
		.enum {
			return g.table.type_size((sym.info as ast.Enum).typ)
		}
		.string {
			return 16, 8
		}
		.array {
			return 32, 8
		}
		.sum_type {
			return 16 + 8 * (sym.info as ast.SumType).fields.len, 8
		}
		.interface {
			return 24 + 8 * (sym.info as ast.Interface).fields.len, 8
		}
		.array_fixed {
			info := sym.info as ast.ArrayFixed
			es, ea := g.vgc_ss_size(info.elem_type)
			if ea <= 0 || info.size < 0 {
				return 0, 0
			}
			return es * info.size, ea
		}
		.struct, .map, .multi_return {
			mut types := []ast.Type{}
			mut is_union := false
			if sym.kind == .multi_return {
				types = (sym.info as ast.MultiReturn).types.clone()
			} else {
				ssym := if sym.kind == .map { g.table.sym(ast.map_type) } else { sym }
				if ssym.info !is ast.Struct || ssym.language != .v {
					return 0, 0
				}
				info := ssym.info as ast.Struct
				if info.is_minify || info.is_typedef || info.attrs.contains('packed') {
					return 0, 0
				}
				is_union = info.is_union
				types = info.fields.map(it.typ)
			}
			mut size := 0
			mut align := 1
			for t in types {
				fs, fa := g.vgc_ss_size(t)
				if fa <= 0 {
					return 0, 0
				}
				if fa > align {
					align = fa
				}
				if is_union {
					if fs > size {
						size = fs
					}
				} else {
					size = (size + fa - 1) / fa * fa + fs
				}
			}
			return (size + align - 1) / align * align, align
		}
		else {
			if sym.language != .v {
				return 0, 0
			}
			return g.table.type_size(typ)
		}
	}
}

// vgc_ss_walk collects typ's leaves: `off` is the byte offset of the value
// walked in the local, `expr` the same as a C constant expression (the pass
// emits that one; vgc_ss_ref checks the two agree), `cname` its C type. False
// for what the walk cannot place — a C type, a reordered struct, a long fixed
// array of references: the caller pins the local.
fn (mut g Gen) vgc_ss_walk(typ_ ast.Type, cname string, off int, expr string, depth int, mut leaves []VgcSsLeaf) bool {
	if depth > 24 || leaves.len > 512 {
		return false
	}
	if typ_.has_flag(.option) || typ_.has_flag(.result) {
		// { u8 state; IError err; u8 data[sizeof(T)]; } — IError: the object
		// pointer, a u32 tag, the method table (8 + 24 bytes before the value)
		leaves << VgcSsLeaf{off, false, expr}
		leaves << VgcSsLeaf{off + 8, true, '${expr} + __builtin_offsetof(${cname}, err)'}
		leaves << VgcSsLeaf{off + 16, false, '${expr} + __builtin_offsetof(${cname}, err) + 8'}
		base := typ_.clear_option_and_result()
		if base.idx() == ast.void_type_idx || base.idx() == ast.none_type_idx || base.idx() == 0 {
			return true
		}
		return g.vgc_ss_walk(base, g.styp(base), off + 32, '${expr} + __builtin_offsetof(${cname}, data)',
			depth + 1, mut leaves)
	}
	typ := g.unwrap_generic(typ_)
	if typ.is_any_kind_of_pointer() || typ.is_ptr() || typ.has_flag(.shared_f)
		|| typ.has_flag(.atomic_f) {
		leaves << VgcSsLeaf{off, true, expr}
		return true
	}
	sym := g.table.sym(typ)
	if sym.kind == .alias {
		parent := (sym.info as ast.Alias).parent_type
		return g.vgc_ss_walk(parent, g.styp(parent), off, expr, depth + 1, mut leaves)
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
			leaves << VgcSsLeaf{off, false, expr}
			return true
		}
		.voidptr, .byteptr, .charptr, .chan, .thread {
			leaves << VgcSsLeaf{off, true, expr}
			return true
		}
		.string {
			// { u8* str; int len; int is_lit; }
			leaves << VgcSsLeaf{off, true, expr}
			leaves << VgcSsLeaf{off + 8, false, '${expr} + 8'}
			leaves << VgcSsLeaf{off + 12, false, '${expr} + 12'}
			return true
		}
		.array {
			// { void* data; int offset; int len; int cap; flags; int element_size; }
			leaves << VgcSsLeaf{off, true, expr}
			for o in [8, 12, 16, 20, 24] {
				leaves << VgcSsLeaf{off + o, false, '${expr} + ${o}'}
			}
			return true
		}
		.sum_type, .interface {
			// a union of pointers (the object pointer), the u32 tag, (an
			// interface's method table: static, no reference,) then pointers to
			// the common fields
			leaves << VgcSsLeaf{off, true, expr}
			leaves << VgcSsLeaf{off + 8, false, '${expr} + 8'}
			mut nfields := 0
			mut first := 16
			if sym.info is ast.SumType {
				nfields = sym.info.fields.len
			} else if sym.info is ast.Interface {
				nfields = sym.info.fields.len
				first = 24
			}
			for i in 0 .. nfields {
				leaves << VgcSsLeaf{off + first + 8 * i, true, '${expr} + ${first + 8 * i}'}
			}
			return true
		}
		.array_fixed {
			info := sym.info as ast.ArrayFixed
			esize, _ := g.vgc_ss_size(info.elem_type)
			if info.size < 0 || esize <= 0 {
				return false
			}
			if !g.contains_ptr(info.elem_type) {
				// no reference in it: a narrow field in each of its words
				total := esize * info.size
				if total > 4096 {
					return false
				}
				for w := 0; w < total; w += 8 {
					leaves << VgcSsLeaf{off + w, false, '${expr} + ${w}'}
				}
				return true
			}
			if info.size > 16 {
				return false
			}
			ecname := g.styp(info.elem_type)
			for i in 0 .. info.size {
				if !g.vgc_ss_walk(info.elem_type, ecname, off + i * esize, '${expr} + ${i} * sizeof(${ecname})',
					depth + 1, mut leaves) {
					return false
				}
			}
			return true
		}
		.struct, .map {
			// a map is the builtin struct `map`
			ssym := if sym.kind == .map { g.table.sym(ast.map_type) } else { sym }
			scname := if sym.kind == .map { 'map' } else { cname }
			if ssym.info !is ast.Struct {
				return false
			}
			info := ssym.info as ast.Struct
			if info.is_minify || info.is_typedef || info.attrs.contains('packed') {
				return false
			}
			mut cur := 0
			for field in info.fields {
				fsize, falign := g.vgc_ss_size(field.typ)
				if falign <= 0 {
					return false
				}
				foff := if info.is_union { 0 } else { (cur + falign - 1) / falign * falign }
				fcname := g.styp(field.typ)
				if !g.vgc_ss_walk(field.typ, fcname, off + foff, '${expr} + __builtin_offsetof(${scname}, ${c_name(field.name)})',
					depth + 1, mut leaves) {
					return false
				}
				if !info.is_union {
					cur = foff + fsize
				}
			}
			return true
		}
		.multi_return {
			info := sym.info as ast.MultiReturn
			mut cur := 0
			for i, t in info.types {
				fsize, falign := g.vgc_ss_size(t)
				if falign <= 0 {
					return false
				}
				foff := (cur + falign - 1) / falign * falign
				if !g.vgc_ss_walk(t, g.styp(t), off + foff, '${expr} + __builtin_offsetof(${cname}, arg${i})',
					depth + 1, mut leaves) {
					return false
				}
				cur = foff + fsize
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
	touched := vgc_ss_touched(body)
	lines := body.split('\n')
	mut out := []string{cap: lines.len + params.len}
	mut pending := ''
	mut depth := 0
	mut first := true
	for line in lines {
		if first && params.len > 0 {
			// the body text starts right after the function's opening `{`
			mut pesc := []string{}
			for p in params {
				pname := p.all_before('\x01')
				if pname in touched {
					esc := p.all_after('\x01').trim_left(' ')
					if vgc_ss_paramread {
						kept := vgc_ss_param_unread(esc, pname, body)
						if kept != '' {
							pesc << kept
						}
					} else {
						pesc << esc
					}
				}
			}
			if pesc.len > 0 {
				out << '\t' + pesc.join(' ')
			}
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
		if line[ns..ne] !in touched {
			// the function only moves this local (no field of it is named, its
			// address is not taken): clang has no narrow access to cut it at
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

// vgc_ss_touched answers the identifiers of a function body's C text that are
// followed by `.` (a field of the local is named) or preceded by `&` (its
// address is taken). SROA cuts a local only at typed accesses to parts of it; a
// local the function declares, assigns, passes and returns whole is one piece.
fn vgc_ss_touched(body string) map[string]bool {
	mut out := map[string]bool{}
	n := body.len
	mut i := 0
	for i < n {
		c := body[i]
		if c == `.` && i > 0 && i + 1 < n && (body[i + 1].is_letter() || body[i + 1] == `_`) {
			mut j := i
			for j > 0 && (body[j - 1].is_letter() || body[j - 1].is_digit() || body[j - 1] == `_`) {
				j--
			}
			if j < i && !body[j].is_digit() {
				out[body[j..i]] = true
			}
		} else if c == `&` && i + 1 < n && (body[i + 1].is_letter() || body[i + 1] == `_`) {
			e := vgc_ss_ident_end(body, i + 1)
			out[body[i + 1..e]] = true
			i = e
			continue
		}
		i++
	}
	return out
}

// vgc_ss_append adds the escape text after the declaration's statement: at the
// line's end, or before a trailing `//` comment (which would swallow it)
fn vgc_ss_append(line string, esc string) string {
	if ci := line.last_index('; //') {
		return line[..ci + 1] + esc + line[ci + 1..]
	}
	return line + esc
}
