// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module c

import v.ast
import v.util
import strings
import v.depgraph

// global or const variable definition string
struct GlobalConstDef {
	mod            string   // module name
	def            string   // definition
	init           string   // init later (in _vinit)
	dep_names      []string // the names of all the consts, that this const depends on
	order          int      // -1 for simple defines, string literals, anonymous function names, extern declarations etc
	is_precomputed bool     // can be declared as a const in C: primitive, and a simple definition
}

// vgc_noscan_storage — the section attribute for the storage of a const or
// `__global` whose type holds no reference (cx-home/cx-core-code#278): an int,
// a float, a bool, an enum, a char or rune, or an alias of one (a duration in
// nanoseconds, a byte count, a clock). Such a word is an integer, never a
// root, and the vgc collector's data-segment scan read it conservatively: a
// value in the arenas' address range (on macOS arm64 0x1_0000_0000-
// 0x2_0000_0000 = 4.3-8.6 s in nanoseconds, 4-8 GB in bytes) rooted whatever
// was carved there — cx-platform-store's `grp_shred_status_wait = 5 *
// time.second` (0x12a05f200) kept a dropped 12 MB array in cx's prof-052.
// The section (vnoscan; mach-o __DATA,__vnoscan) is left out of the scan
// (vgc_noscan_ranges, thirdparty/vgc/vgc_platform.h; vgc_const_word_selftest).
// usize and isize stay scanned: the collector's own address-sized globals hold
// span addresses on purpose (vgc_perm_slab_end, excluded by name). Only under
// -gc e, on the mach-o and ELF targets the collector reads the section on.
fn (g &Gen) vgc_noscan_storage(typ ast.Type) string {
	if g.pref.gc_mode != .vgc || typ.is_ptr() || typ.nr_muls() > 0 {
		return ''
	}
	sym := g.table.final_sym(typ)
	if sym.kind !in [.bool, .i8, .i16, .i32, .int, .i64, .u8, .u16, .u32, .u64, .f32, .f64,
		.char, .rune, .enum, .int_literal, .float_literal] {
		return ''
	}
	return match g.pref.os {
		.macos, .ios { '__attribute__ ((section ("__DATA,__vnoscan"))) ' }
		.linux, .freebsd, .openbsd, .netbsd, .dragonfly { '__attribute__ ((section ("vnoscan"))) ' }
		else { '' }
	}
}

fn (mut g Gen) const_decl(node ast.ConstDecl) {
	g.inside_const = true
	defer {
		g.inside_const = false
	}
	for field in node.fields {
		if g.pref.skip_unused {
			if field.name !in g.table.used_features.used_consts {
				$if trace_skip_unused_consts ? {
					eprintln('>> skipping unused const name: ${field.name}')
				}
				continue
			}
		}
		name := c_name(field.name)
		const_name := g.c_const_name(field.name)
		field_expr := field.expr
		if field.attrs.contains('cinit') || node.attrs.contains('cinit') {
			styp := g.styp(field.typ)
			val := g.expr_string(field.expr)
			g.global_const_defs[name] = GlobalConstDef{
				mod:       field.mod
				def:       '${g.static_non_parallel}${styp} ${const_name} = ${val};'
				dep_names: g.table.dependent_names_in_expr(field.expr)
			}
			continue
		}
		match field.expr {
			ast.ArrayInit {
				elems_are_const := field.expr.exprs.all(g.check_expr_is_const(it))
				if field.expr.is_fixed && !field.expr.has_index
					&& (!g.is_cc_msvc || field.expr.elem_type != ast.string_type) && elems_are_const {
					// Initialize fixed-array consts at their C *definition* (`static T x =
					// {..}`), not in _vinit: a fixed C array is not assignable (`x = {..}`
					// is illegal), so a deferred runtime init cannot work for them. This
					// used to be gated to non-build_module (cached modules deferred all
					// const init to the program TU) — but a cached module now runs its own
					// ${mod}__init_consts(), and emitting `x = {..}` there is exactly the
					// illegal form. Initializing at definition is valid in every TU.
					styp := g.styp(field.expr.typ)
					val := g.expr_string(ast.Expr(field.expr))
					// eprintln('> const_name: ${const_name} | name: ${name} | styp: ${styp} | val: ${val}')
					g.global_const_defs[name] = GlobalConstDef{
						mod:       field.mod
						def:       '${g.static_non_parallel}${styp} ${const_name} = ${val}; // fixed array const'
						dep_names: g.table.dependent_names_in_expr(field_expr)
					}
				} else if field.expr.is_fixed && !field.expr.has_index
					&& ((g.is_cc_msvc && field.expr.elem_type == ast.string_type)
					|| !elems_are_const) {
					g.const_decl_init_later_msvc_string_fixed_array(field.mod, name, const_name,
						field.expr, field.typ)
				} else if !field.expr.is_fixed && g.const_array_is_static(field.expr) {
					// https://github.com/cx-home/cx-private/issues/2068: a const array literal of
					// literals is static C data; _vinit only points the array at it (no heap copy).
					elem_styp := g.styp(field.expr.elem_type)
					n := field.expr.exprs.len
					mut vals := []string{cap: n}
					for e in field.expr.exprs {
						if e is ast.StringLiteral {
							escaped := cescape_nonascii(util.smart_quote(e.val, e.is_raw))
							vals << '_SINIT(${cescaped_string_literal(escaped)})'
						} else {
							vals << '(${elem_styp})(${g.expr_string(e)})'
						}
					}
					g.global_const_defs[name] = GlobalConstDef{
						mod:   field.mod
						def:   '${g.static_non_parallel}${elem_styp} ${const_name}__sdata[${n}] = {${vals.join(', ')}};\n${g.static_non_parallel}${g.styp(field.typ)} ${const_name}; // a const array of literals: static data'
						init:  '\t${const_name} = builtin__new_array_static(${n}, sizeof(${elem_styp}), ${const_name}__sdata);'
						order: -1
					}
				} else {
					g.const_decl_init_later(field.mod, name, const_name, ast.Expr(field.expr),
						field.typ, false)
				}
			}
			ast.StringLiteral {
				val := g.expr_string(ast.Expr(field.expr))
				typ := if field.expr.language == .c { 'char*' } else { 'string' }
				g.global_const_defs[name] = GlobalConstDef{
					mod:   field.mod
					def:   '${g.static_non_parallel}${typ} ${const_name}; // a string literal, inited later'
					init:  '\t${const_name} = ${val};'
					order: -1
				}
			}
			ast.CallExpr {
				if field.expr.return_type.has_flag(.option)
					|| field.expr.return_type.has_flag(.result) {
					old_inside_const_opt_or_res := g.inside_const_opt_or_res
					g.inside_const_opt_or_res = true
					unwrap_opt_res := field.expr.or_block.kind != .absent
					g.const_decl_init_later(field.mod, name, const_name, ast.Expr(field.expr),
						field.typ, unwrap_opt_res)
					g.inside_const_opt_or_res = old_inside_const_opt_or_res
				} else {
					g.const_decl_init_later(field.mod, name, const_name, ast.Expr(field.expr),
						field.typ, false)
				}
			}
			else {
				// Note: -usecache uses prebuilt modules, each compiled with:
				// `v build-module vlib/module`
				// combined with a top level program, that is compiled with:
				// `v -usecache toplevel`
				// For it to work, the consts optimisations should be identical, because
				// only the top level program will have the const initialisation code for
				// all the modules.
				// TODO: encapsulate const initialisation for each module in a separate function,
				// that is just called by the top level program in _vinit, instead of generating
				// all the code inside _vinit for each module.
				use_cache_mode := g.pref.build_mode == .build_module || g.pref.use_cache
				if !use_cache_mode {
					if ct_value := field.comptime_expr_value() {
						if g.const_decl_precomputed(field.mod, name, const_name, field.name,
							ct_value, field.typ)
						{
							continue
						}
					}
					// An integer const the evaluator above leaves alone (a usize or
					// isize one: `usize(64) * 1024 * 1024`) whose initialiser C
					// folds gets its value in its C definition, as such a __global
					// does (global_decl): a _vinit statement left it 0 for the
					// _vinit statements before it, and builtin's consts allocate
					// there, so the collector read its own sizes as 0.
					if field.typ.is_int() && g.const_expr_is_c_int_const(field.expr) {
						g.const_decl_write_precomputed(field.mod, g.styp(field.typ), const_name,
							field.name, '(${g.expr_string(field.expr)})')
						continue
					}
				}
				if field.is_simple_define_const() {
					// "Simple" expressions are not going to need multiple statements,
					// only the ones which are inited later, so it's safe to use expr_string
					g.const_decl_simple_define(field.mod, field.name, const_name,
						g.expr_string(field_expr))
				} else if field.expr is ast.CastExpr {
					if field.expr.expr is ast.ArrayInit {
						if field.expr.expr.is_fixed {
							// Fixed-array cast const: initialize at definition, valid in
							// every TU (a fixed C array cannot be assigned at runtime; see
							// the ArrayInit fixed-array case above).
							styp := g.styp(field.expr.typ)
							val := g.expr_string(field.expr.expr)
							g.global_const_defs[name] = GlobalConstDef{
								mod:       field.mod
								def:       '${g.static_non_parallel}${styp} ${const_name} = ${val}; // fixed array const'
								dep_names: g.table.dependent_names_in_expr(field_expr)
							}
							continue
						}
					}
					should_surround := field.expr.expr is ast.CallExpr
						&& field.expr.expr.or_block.kind != .absent
					g.const_decl_init_later(field.mod, name, const_name, ast.Expr(field.expr),
						field.typ, should_surround)
				} else if field.expr is ast.InfixExpr {
					mut has_unwrap_opt_res := false
					if field.expr.left is ast.CallExpr {
						has_unwrap_opt_res = field.expr.left.or_block.kind != .absent
					} else if field.expr.right is ast.CallExpr {
						has_unwrap_opt_res = field.expr.right.or_block.kind != .absent
					}
					g.const_decl_init_later(field.mod, name, const_name, ast.Expr(field.expr),
						field.typ, has_unwrap_opt_res)
				} else {
					g.const_decl_init_later(field.mod, name, const_name, field.expr, field.typ,
						true)
				}
			}
		}
	}
}

fn (mut g Gen) const_decl_precomputed(mod string, name string, cname string, field_name string, ct_value ast.ComptTimeConstValue,
	typ ast.Type) bool {
	mut styp := g.styp(typ)
	$if trace_const_precomputed ? {
		eprintln('> styp: ${styp} | cname: ${cname} | ct_value: ${ct_value} | ${ct_value.type_name()}')
	}
	match ct_value {
		i8 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		}
		i16 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		}
		i32 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		}
		// int {
		// XTODO int64
		// g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		//}
		i64 {
			if typ == ast.i64_type {
				return false
			}
			if typ == ast.int_type {
				// TODO: use g.const_decl_write_precomputed here too.
				// For now, use #define macros, so existing code compiles
				// with -cstrict. Add checker errors for overflows instead,
				// so V can catch them earlier, instead of relying on the
				// C compiler for that.
				g.const_decl_simple_define(mod, name, cname, ct_value.str())
				return true
			}
			if typ == ast.u64_type {
				g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str() + 'U')
			} else {
				g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
			}
		}
		u8 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		}
		u16 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		}
		u32 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		}
		u64 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str() + 'U')
		}
		f32 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		}
		f64 {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, ct_value.str())
		}
		rune {
			rune_code := u32(ct_value)
			if rune_code <= 127 {
				if rune_code in [`"`, `\\`, `'`] {
					return false
				}
				escval := if rune_code < 32 || rune_code == 127 {
					// Control characters cannot appear verbatim inside a C char
					// literal: a raw `\r` would even split the `#define` line and
					// break compilation. Emit a portable octal escape instead,
					// mirroring char_literal().
					mut sb := strings.new_builder(4)
					write_octal_escape(mut sb, u8(rune_code))
					sb.str()
				} else {
					util.smart_quote(u8(rune_code).ascii_str(), false)
				}

				g.global_const_defs[util.no_dots(field_name)] = GlobalConstDef{
					mod:   mod
					def:   "#define ${cname} '${escval}'"
					order: -1
				}
			} else {
				g.const_decl_write_precomputed(mod, styp, cname, field_name, u32(ct_value).str())
			}
		}
		string {
			escaped_val := util.smart_quote(ct_value, false)
			// g.const_decl_write_precomputed(line_nr, styp, cname, '_S("${escaped_val}")')
			// TODO: ^ the above for strings, cause:
			// `error C2099: initializer is not a constant` errors in MSVC,
			// so fall back to the delayed initialisation scheme:
			init := if typ == ast.string_type {
				'_S(${cescaped_string_literal(escaped_val)})'
			} else {
				'(${styp})${cescaped_string_literal(escaped_val)}'
			}
			g.global_const_defs[util.no_dots(field_name)] = GlobalConstDef{
				mod:   mod
				def:   '${g.static_non_parallel}${styp} ${cname}; // str inited later'
				init:  '\t${cname} = ${init};'
				order: -1
			}
			if g.is_autofree {
				g.cleanups[mod].writeln('\tbuiltin__string_free(&${cname});')
			}
		}
		voidptr {
			g.const_decl_write_precomputed(mod, styp, cname, field_name, '(voidptr)(0x${ct_value})')
		}
		ast.EmptyComptimeConstValue {
			return false
		}
	}

	return true
}

fn (mut g Gen) const_decl_write_precomputed(mod string, styp string, cname string, field_name string, ct_value string) {
	if g.pref.is_livemain || g.pref.is_liveshared {
		// Note: tcc has problems reloading .so files with consts in them, when the consts are then used inside the reloaded
		// live functions. As a workaround, just use simple #define macros in this case.
		//
		// If you change it, please also test with `v -live run examples/hot_reload/graph.v` which uses `math.pi` .
		g.global_const_defs[util.no_dots(field_name)] = GlobalConstDef{
			mod:   mod
			def:   '#define ${cname} ${ct_value} // precomputed3, -live mode'
			order: -1
		}
		return
	}
	g.global_const_defs[util.no_dots(field_name)] = GlobalConstDef{
		mod: mod
		def: '${g.static_non_parallel}const ${styp} ${cname} = ${ct_value}; // precomputed2'
		// is_precomputed: true
	}
}

fn (mut g Gen) const_decl_simple_define(mod string, name string, cname string, val string) {
	// Simple expressions should use a #define
	// so that we don't pollute the binary with unnecessary global vars
	// Do not do this when building a module, otherwise the consts
	// will not be accessible.
	if g.pref.translated {
		g.global_const_defs[util.no_dots(name)] = GlobalConstDef{
			mod:   mod
			def:   '${g.static_non_parallel}const ${ast.int_type_name} ${cname} = ${val};'
			order: -1
		}
	} else {
		g.global_const_defs[util.no_dots(name)] = GlobalConstDef{
			mod:   mod
			def:   '#define ${cname} ${val}'
			order: -1
		}
	}
}

fn (mut g Gen) c_const_name(name string) string {
	if name in g.table.export_names {
		// `@[export] name
		return g.table.export_names[name]
	}
	mut const_name := util.no_dots(name)
	if g.pref.translated && !g.is_builtin_mod && !util.module_is_builtin(name.all_before_last('.')) {
		if name.starts_with('main.') {
			const_name = util.no_dots(name.all_after_first('main.'))
		}
	}

	return if g.pref.translated && !g.is_builtin_mod {
		const_name
	} else {
		'_const_' + g.get_ternary_name(c_name(name))
	}
}

fn (mut g Gen) const_decl_init_later(mod string, name string, cname string, expr ast.Expr, typ ast.Type, surround_cbr bool) {
	if name.starts_with('C__') {
		return
	}
	// Initialize more complex consts in `void _vinit/2{}`
	// (C doesn't allow init expressions that can't be resolved at compile time).
	mut styp := g.styp(typ)
	mut init := strings.new_builder(100)

	if surround_cbr {
		init.writeln('{')
	}
	if (expr is ast.ArrayInit && expr.has_index)
		|| (expr is ast.IfExpr && g.table.type_kind(expr.typ) == .array_fixed) {
		init.writeln(g.expr_string_surround('\tmemcpy(&${cname}, &', expr, ', sizeof(${styp}));'))
	} else if expr is ast.CallExpr
		&& g.table.final_sym(g.unwrap_generic((expr as ast.CallExpr).return_type)).kind == .array_fixed {
		init.writeln(g.expr_string_surround('\tmemcpy(&${cname}, ', expr, ', sizeof(${styp}));'))
	} else {
		init.writeln(g.expr_string_surround('\t${cname} = ', expr, ';'))
	}
	if surround_cbr {
		init.writeln('}')
	}
	// cx-home/cx-core-code#278: a pointer-free const's storage is not a root
	mut def := '${g.static_non_parallel}${styp} ${g.vgc_noscan_storage(typ)}${cname}'
	if g.pref.parallel_cc {
		// So that the const is usable in other files
		// def = 'extern ${def}'
	}
	expr_sym := g.table.sym(typ)
	if expr_sym.kind == .function {
		// allow for: `const xyz = abc`, where `abc` is `fn abc() {}`
		func := (expr_sym.info as ast.FnType).func
		def = g.fn_var_signature(ast.void_type, func.return_type, func.params.map(it.typ), cname)
	}
	init_str := init.str().trim_right('\n')
	g.global_const_defs[util.no_dots(name)] = GlobalConstDef{
		mod:       mod
		def:       '${def}; // inited later'
		init:      if init_str.count('\n') > 1 {
			'{\n${init_str}\n}'
		} else {
			init_str
		}
		dep_names: g.table.dependent_names_in_expr(expr)
	}
	if g.is_autofree {
		sym := g.table.sym(typ)
		if sym.kind == .array {
			if sym.has_method_with_generic_parent('free') {
				g.cleanup.writeln('\t${styp}_free(&${cname});')
			} else {
				g.cleanup.writeln('\tbuiltin__array_free(&${cname});')
			}
		} else if styp == 'string' {
			g.cleanup.writeln('\tbuiltin__string_free(&${cname});')
		} else if sym.kind == .map {
			g.cleanup.writeln('\tbuiltin__map_free(&${cname});')
		} else if styp == 'IError' {
			g.cleanup.writeln('\tbuiltin__IError_free(&${cname});')
		}
	}
}

fn (mut g Gen) const_decl_init_later_msvc_string_fixed_array(mod string, name string, cname string, expr ast.ArrayInit,
	typ ast.Type) {
	mut styp := g.styp(typ)
	mut init := strings.new_builder(100)
	for i, elem_expr in expr.exprs {
		if elem_expr is ast.ArrayInit && elem_expr.is_fixed {
			elem_typ := g.styp(elem_expr.typ)
			init.writeln(g.expr_string_surround('\tmemcpy(${cname}[${i}], (${elem_typ})',
				elem_expr, ', sizeof(${elem_typ}));'))
		} else if elem_expr is ast.Ident {
			elem_typ := elem_expr.obj.typ
			if g.table.final_sym(elem_typ).kind == .array_fixed {
				elem_styp := g.styp(elem_expr.obj.typ)
				init.writeln(g.expr_string_surround('\tmemcpy(${cname}[${i}], ', elem_expr,
					', sizeof(${elem_styp}));'))
			} else {
				init.writeln(g.expr_string_surround('\t${cname}[${i}] = ', elem_expr, ';'))
			}
		} else {
			init.writeln(g.expr_string_surround('\t${cname}[${i}] = ', elem_expr, ';'))
		}
	}
	mut def := '${g.static_non_parallel}${styp} ${cname}'
	g.global_const_defs[util.no_dots(name)] = GlobalConstDef{
		mod:       mod
		def:       '${def}; // inited later'
		init:      init.str().trim_right('\n')
		dep_names: g.table.dependent_names_in_expr(expr)
	}
	if g.is_autofree {
		sym := g.table.sym(typ)
		if sym.has_method_with_generic_parent('free') {
			if sym.is_builtin() {
				g.cleanup.writeln('\tbuiltin__${styp}_free(&${cname});')
			} else {
				g.cleanup.writeln('\t${styp}_free(&${cname});')
			}
		} else {
			g.cleanup.writeln('\tbuiltin__array_free(&${cname});')
		}
	}
}

fn (mut g Gen) global_const_expr_is_c_const(expr ast.Expr) bool {
	match expr {
		ast.BoolLiteral, ast.CharLiteral, ast.EnumVal, ast.FloatLiteral, ast.IntegerLiteral,
		ast.Nil, ast.SizeOf, ast.StringLiteral {
			return true
		}
		ast.ArrayInit {
			if !expr.is_fixed || expr.has_len || expr.has_cap || expr.has_init || expr.has_index {
				return false
			}
			for item in expr.exprs {
				if !g.global_const_expr_is_c_const(item) {
					return false
				}
			}
			return true
		}
		ast.CastExpr {
			return !expr.has_arg && g.global_const_expr_is_c_const(expr.expr)
		}
		ast.Ident {
			return expr.kind == .function
				|| (expr.obj is ast.ConstField && expr.obj.is_simple_define_const())
		}
		ast.InfixExpr {
			if expr.left_type == ast.string_type || expr.right_type == ast.string_type
				|| expr.promoted_type == ast.string_type {
				return false
			}
			return g.global_const_expr_is_c_const(expr.left)
				&& g.global_const_expr_is_c_const(expr.right)
		}
		ast.ParExpr {
			return g.global_const_expr_is_c_const(expr.expr)
		}
		ast.PrefixExpr {
			if expr.op == .amp {
				return expr.right is ast.Ident || expr.right is ast.SelectorExpr
			}
			return g.global_const_expr_is_c_const(expr.right)
		}
		ast.SelectorExpr {
			return expr.expr is ast.Ident && expr.expr.name == 'C'
		}
		ast.StructInit {
			if expr.has_update_expr {
				return false
			}
			for field in expr.init_fields {
				if !g.global_const_expr_is_c_const(field.expr) {
					return false
				}
			}
			return true
		}
		ast.UnsafeExpr {
			return g.global_const_expr_is_c_const(expr.expr)
		}
		else {
			return false
		}
	}
}

// const_expr_is_c_int_const answers whether cgen writes integer expression `expr`
// as a C integer constant expression: integer and character literals, a
// #define const, a cast to an integer type, and the operators cgen writes as C's
// own (+ - * & | ^, unary - and ~). A shift, a division and a modulo are not:
// cgen writes them as calls or checked macros (v__lshift_usize, VSAFE_DIV_*).
fn (mut g Gen) const_expr_is_c_int_const(expr ast.Expr) bool {
	match expr {
		ast.CharLiteral, ast.IntegerLiteral {
			return true
		}
		ast.CastExpr {
			return !expr.has_arg && expr.typ.is_int() && g.const_expr_is_c_int_const(expr.expr)
		}
		ast.Ident {
			return expr.obj is ast.ConstField && expr.obj.is_simple_define_const()
				&& expr.obj.expr is ast.IntegerLiteral
		}
		ast.InfixExpr {
			if expr.op !in [.plus, .minus, .mul, .amp, .pipe, .xor] {
				return false
			}
			return g.const_expr_is_c_int_const(expr.left) && g.const_expr_is_c_int_const(expr.right)
		}
		ast.ParExpr {
			return g.const_expr_is_c_int_const(expr.expr)
		}
		ast.PrefixExpr {
			return expr.op in [.minus, .bit_not] && g.const_expr_is_c_int_const(expr.right)
		}
		else {
			return false
		}
	}
}

// global_c_value_calls reports whether the C text cgen writes for a global's
// value calls something: V writes a shift as `v__lshift_*` / `v__rshift_*`, an
// integer `/` or `%` as `VSAFE_DIV_*` / `VSAFE_MOD_*` and, with overflow checks
// on, `+ - *` as `builtin__overflow__*`. A C static initializer refuses a call
// (cc: "initializer element is not a compile-time constant"), so such a value
// is assigned in `_vinit` (cx-home/cx-core-code#268:
// vlib/v/tests/consts/const_number_c_expr_call_test.v)
fn (mut g Gen) global_c_value_calls(expr ast.Expr) bool {
	match expr {
		ast.CastExpr, ast.InfixExpr, ast.ParExpr, ast.PrefixExpr, ast.UnsafeExpr {
			return c_text_has_call(g.expr_string(expr))
		}
		else {
			return false
		}
	}
}

// c_text_has_call reports whether C text `s` calls something: a `(` whose
// nearest non-space character before it ends a name (`f(`) other than
// `sizeof` / `_Alignof`, not a cast or a group (`((u64)(1))`)
fn c_text_has_call(s string) bool {
	for i := 0; i < s.len; i++ {
		if s[i] != `(` {
			continue
		}
		mut j := i - 1
		for j >= 0 && s[j] == ` ` {
			j--
		}
		if j < 0 || !(s[j].is_letter() || s[j].is_digit() || s[j] == `_`) {
			continue
		}
		mut k := j
		for k >= 0 && (s[k].is_letter() || s[k].is_digit() || s[k] == `_`) {
			k--
		}
		if s[k + 1..j + 1] !in ['sizeof', '_Alignof', '__alignof__'] {
			return true
		}
	}
	return false
}

fn (mut g Gen) global_decl(node ast.GlobalDecl) {
	// was static used here to to make code optimizable? it was removed when
	// 'extern' was used to fix the duplicate symbols with usecache && clang
	// visibility_kw := if g.pref.build_mode == .build_module && g.is_builtin_mod { 'static ' }
	// A global owned by the `main` module is only ever compiled into the program
	// TU — `main` is never emitted as a cached `.o` (see Builder.handle_usecache,
	// which caches builtin + imports + non-main test files, but never `main`).
	// So under -usecache it must be *defined* here, not declared `extern`: an
	// `extern` with no definition site links to nothing (the historic `test_runner`
	// "Undefined symbols" failure). Every other module either owns a cached object
	// (defined there, `extern` here) or is bundled (already excluded below).
	is_program_module_global := g.pref.build_mode != .build_module && node.mod == 'main'
	// A bundled module (builtin.closure, builtin.overflow, ...) is compiled into
	// the program TU only, never as its own cached object — so the program TU owns
	// its globals and every build_module compile must reference them `extern`. The
	// historic tentative definition per TU relied on the linker merging common
	// symbols, which current Apple ld and lld no longer do (duplicate-symbol error).
	is_bundled_mod := util.should_bundle_module(node.mod)
	// NATV-18 (cx-home/v#47): vgc_wb_lo / vgc_wb_len are the store gate's range
	// (and vgc_wb_epoch the stop count its second gate reads, and vgc_wb_cards the
	// chunk card tables the gate reads the card through, cx-home/v#56),
	// declared `extern` in the C headers (cgen's vgc_wb_gate and
	// thirdparty/vgc/vgc_native.h) for every unit that stores, native ones
	// included; an object-file build (-o x.o) gave them object-local linkage, and
	// `static` after the headers' `extern` is a C error (no -gc e object built).
	is_vgc_abi_global := node.mod == 'builtin'
		&& node.fields.any(it.name.all_after_last('.') in ['vgc_wb_lo', 'vgc_wb_len', 'vgc_wb_epoch', 'vgc_wb_cards', 'vgc_young_lo', 'vgc_young_len'])
	visibility_kw := if g.should_use_object_local_linkage(node.mod) && !is_vgc_abi_global {
		'static '
	} else if g.pref.build_mode == .build_module && is_bundled_mod {
		'extern '
	} else if
		(g.pref.use_cache || (g.pref.build_mode == .build_module && g.module_built != node.mod))
		&& !is_bundled_mod && !is_program_module_global && node.mod !in g.pref.usecache_invalid_mods {
		// cx-private#864: an invalidated module's layer is not linked, so its
		// globals are DEFINED here, not referenced extern.
		'extern '
	} else {
		''
		// g.static_modifier // TODO: used to be '' before parallel_cc, may cause issues
	}
	// should the global be initialized now, not later in `vinit()`
	cinit := node.attrs.contains('cinit')
	g.inside_cinit = cinit
	g.inside_global_decl = true
	defer {
		g.inside_cinit = false
		g.inside_global_decl = false
	}
	// The last two terms: bundled-module globals (the program TU is their single
	// definition site; cached objects reference them `extern` — see
	// visibility_kw above), and cx-private#864's invalidated-layer modules, which
	// are inline, so their globals initialize here like any non-cached build.
	// (No comment lines between the terms: a parser keeping comments ends the
	// expression there — v_parser_test, cx-private#1894.)
	should_init := (!g.pref.use_cache && g.pref.build_mode != .build_module)
		|| (g.pref.build_mode == .build_module && g.module_built == node.mod)
		|| is_program_module_global
		|| (g.pref.use_cache && g.pref.build_mode != .build_module && is_bundled_mod)
		|| (g.pref.use_cache && g.pref.build_mode != .build_module
		&& node.mod in g.pref.usecache_invalid_mods)
	mut attributes := ''
	first_field := node.fields[0]
	if first_field.is_weak {
		attributes += 'VWEAK '
	}
	if first_field.is_hidden {
		attributes += 'VHIDDEN '
	}
	if first_field.is_exported {
		attributes += 'VV_EXP '
	}
	if attr := node.attrs.find_first('_linker_section') {
		attributes += '__attribute__ ((section ("${attr.arg}"))) '
	}
	for field in node.fields {
		name := c_name(field.name)
		if g.pref.skip_unused {
			if field.name !in g.table.used_features.used_globals {
				$if trace_skip_unused_globals ? {
					eprintln('>> skipping unused global name: ${field.name}')
				}
				continue
			}
		}
		styp := g.styp(field.typ)
		mut def_builder := strings.new_builder(100)
		mut init := ''
		extern := if field.is_extern { 'extern ' } else { '' }
		// `g_main_argc`/`g_main_argv` are owned by the program entry point: the
		// generated `main()` assigns them (gen_c_main_function_header) and their
		// declared initializer is suppressed everywhere (see the skip below). So no
		// module's build_module compile ever *defines* them — under -usecache the
		// owning builtin object only declares them `extern` too, leaving them defined
		// NOWHERE (a non-cache build gets a tentative definition in its single TU).
		// Define them in the program TU (build_mode != build_module): emit '' visibility
		// → a tentative definition that `main()` then fills, mirroring the non-cache
		// build. Cached modules keep referencing them `extern`.
		is_argv_global := field.name in ['g_main_argc', 'g_main_argv']
		program_owned_argv_global := g.pref.build_mode != .build_module && is_argv_global
		field_visibility_kw := if field.is_extern {
			''
		} else if program_owned_argv_global && !g.pref.is_o {
			// (an -is_o object keeps upstream's visibility: several are linked
			// into one host program, and a public definition in each of them was
			// a duplicate symbol — link_generated_c_files_test, cx-private#1894)
			''
		} else if g.pref.build_mode == .build_module && is_argv_global {
			// builtin declares these, but the program TU owns them (its `main()`
			// assigns them) — builtin's own cached object must not emit the
			// historic tentative definition (no longer merged at link, see above).
			'extern '
		} else {
			visibility_kw
		}
		// `extern ` visibility + `!should_init` means this global is *defined* (and
		// initialized) in some OTHER translation unit — its owning module's cached
		// object — while the current TU only references it. (`should_init` is true in
		// the owning module's own build_module compile, where `extern T x = {..}` is
		// the intended single definition.) When merely referencing, emit the
		// declaration only: an initializer here is wrong — `extern T x = {..}` is
		// itself a definition in C → duplicate symbol at link (notably hit by
		// fixed-array globals, whose init is forced inline below, e.g. vgc_*/autostr
		// globals defined into every cached module that touches builtin), and a
		// `_vinit` initializer would redundantly re-init the cached definition.
		// The argv globals are declared by builtin but owned by the program TU even
		// in builtin's own build_module compile (should_init is true there, which
		// would otherwise turn the `extern` into `extern ... = 0;` — a definition).
		global_defined_elsewhere := (field_visibility_kw == 'extern ' && !should_init)
			|| (g.pref.build_mode == .build_module && is_argv_global)
		mut qualifiers := ''
		if field.is_const {
			qualifiers += 'const '
		}
		if field.is_volatile {
			qualifiers += 'volatile '
		}
		// `@[thread_local] __global x` → per-thread storage via the `__thread`
		// GCC/Clang/tcc extension; without it the global is process-shared and
		// concurrent users race. Forward-ported onto upstream's `qualifiers`
		// (replaced the old volatile-only `modifier`).
		if node.attrs.contains('thread_local') {
			qualifiers += '__thread '
		}
		final_c_name := field.name.all_after('C.')
		if field.is_const {
			if field.is_extern || field_visibility_kw == 'extern ' {
				def_builder.writeln('${extern}${field_visibility_kw}${qualifiers}${styp} ${attributes}${final_c_name}; // global 2')
				g.global_const_defs[name] = GlobalConstDef{
					mod:   node.mod
					def:   def_builder.str()
					order: -1
				}
				continue
			}
			if !field.has_expr {
				g.error('const globals must have an explicit initializer', field.pos)
				continue
			}
			if !g.global_const_expr_is_c_const(field.expr) {
				g.error('const global `${field.name}` must be initialized with a C constant expression',
					field.pos)
				continue
			}
			def_builder.write_string('${extern}${field_visibility_kw}${qualifiers}${styp} ${attributes}${final_c_name}')
			def_builder.write_string(' = ${g.expr_string(field.expr)}')
			def_builder.writeln('; // global 2')
			g.global_const_defs[name] = GlobalConstDef{
				mod:   node.mod
				def:   def_builder.str()
				order: -1
			}
			continue
		}
		mut anon_fn_expr := unsafe { field.expr }
		if field.has_expr && mut anon_fn_expr is ast.AnonFn {
			g.gen_anon_fn_decl(mut anon_fn_expr)
			fn_type_name := g.get_anon_fn_type_name(mut anon_fn_expr, field.name)
			g.global_const_defs[util.no_dots(fn_type_name)] = GlobalConstDef{
				mod:   node.mod
				def:   '${fn_type_name} = ${g.table.sym(field.typ).name}; // global 1'
				order: -1
			}
			continue
		}
		if field.is_extern {
			tls_kw := if field.name == 'g_memory_block' && g.pref.prealloc {
				'_Thread_local '
			} else {
				''
			}
			def_builder.writeln('${extern}${tls_kw}${field_visibility_kw}${qualifiers}${styp} ${attributes}${final_c_name}; // global 2')
			g.global_const_defs[name] = GlobalConstDef{
				mod:   node.mod
				def:   def_builder.str()
				order: -1
			}
			continue
		}
		mut needs_ending_semicolon := false
		if field.language != .c || field.has_expr {
			tls_kw := if field.name == 'g_memory_block' && g.pref.prealloc {
				'_Thread_local '
			} else {
				''
			}
			// cx-home/cx-core-code#278: a pointer-free global's storage is not a
			// root — on its definition, not on a declaration of another unit's,
			// a thread-local or one with a section of its own
			noscan := if global_defined_elsewhere || extern != '' || tls_kw != ''
				|| node.attrs.contains('thread_local') || node.attrs.contains('_linker_section') {
				''
			} else {
				g.vgc_noscan_storage(field.typ)
			}
			def_builder.write_string('${extern}${tls_kw}${field_visibility_kw}${qualifiers}${styp} ${attributes}${noscan}${final_c_name}')
			needs_ending_semicolon = true
		}
		if global_defined_elsewhere {
			// Declaration only — the owning cached object defines + initializes it.
		} else if field.has_expr || cinit {
			// `__global x = unsafe { nil }` should still use the simple direct initialisation, `g_main_argv` needs it.
			mut is_simple_unsafe_expr := false
			if field.expr is ast.UnsafeExpr {
				if field.expr.expr is ast.Nil {
					is_simple_unsafe_expr = true
				}
				if field.expr.expr.is_literal() {
					is_simple_unsafe_expr = true
				}
			}
			if g.pref.translated {
				def_builder.write_string(' = ${g.expr_string(field.expr)}')
			} else if (field.expr.is_literal() && should_init && !g.global_c_value_calls(field.expr))
				|| cinit || (field.expr is ast.ArrayInit && field.expr.is_fixed)
				|| (is_simple_unsafe_expr && should_init)
				|| (should_init && field.typ != ast.string_type && field.expr !is ast.StructInit
				&& g.global_const_expr_is_c_const(field.expr) && !g.global_c_value_calls(field.expr)) {
				// Simple literals can be initialized right away in global scope in C.
				// e.g. `int myglobal = 10;`
				// So can any C constant expression (`usize(0)`, `&u8(unsafe { nil })`):
				// assigned in `_vinit` instead, the statement ran after every earlier
				// module's consts and overwrote what they had already stored through
				// the global (builtin's consts allocate before the collector's
				// globals' statements: `vgc_arena_lo = usize(0)` dropped the first
				// arena from the heap's address range; vgc_heap_vinit_kept_test.v).
				def_builder.write_string(' = ${g.expr_string(field.expr)}')
			} else {
				// More complex expressions need to be moved to `_vinit()`
				// e.g. `__global ( mygblobal = 'hello ' + world' )`
				if field.name in ['g_main_argc', 'g_main_argv'] {
					init = '\t// skipping ${final_c_name}, it was initialised in main'
				} else if field.expr is ast.StructInit && field.expr.init_fields.len == 0
					&& !field.expr.has_update_expr && g.global_zero_default(field.typ, 0) {
					// `__global x = T{}` of a T whose every field defaults to
					// zero: `x = (T){…}` builds the whole T as a stack temporary
					// in `_vinit` at -O0 (vgc_heap: ~2 MB, cx-home/v#32 — a 2 MB
					// stack overflowed in `_vinit`); memset writes the same zeros
					if should_init {
						// The definition is here, and its static storage starts
						// zero: no `_vinit` statement at all. A memset in
						// `_vinit` ran AFTER every earlier module's consts, and
						// wiped what they had already stored through the global:
						// builtin's consts allocate before `vgc_heap`'s
						// statement, so the collector forgot their spans
						// (6 spans, 49,152 B carved still mapped;
						// vgc_heap_vinit_kept_test.v).
						def_builder.write_string(' = {0}')
						init = '\t// ${final_c_name}: zero from its definition // global 3z'
					} else {
						init = '\tmemset(&${final_c_name}, 0, sizeof(${styp})); // global 3z'
					}
				} else {
					init = '\t${final_c_name} = ${g.expr_string(field.expr)}; // global 3'
				}
			}
		} else if !g.pref.translated && field.language == .v {
			// don't zero globals from C code
			g.type_default_vars.clear()
			default_initializer := g.type_default(field.typ)
			if default_initializer == '{0}' && should_init {
				def_builder.write_string(' = {0}')
			} else if default_initializer == '{E_STRUCT}' && should_init {
				init = '\tmemcpy(${final_c_name}, (${styp}){${default_initializer}}, sizeof(${styp})); // global 4'
			} else {
				if field.name !in ['as_cast_type_indexes', 'g_memory_block', 'global_allocator'] {
					decls := g.type_default_vars.str()
					if decls != '' {
						init = '\t${decls}'
					}
					// Fixed-size C arrays (`[N]T`) are not assignable with `=`, so
					// the `dst = *(T*)&((T[]){..}[0])` form emits illegal C ("array
					// type ... is not assignable") when this runs in `_vinit` rather
					// than at declaration — the path taken under `-usecache`/build_module.
					// memcpy the default in, mirroring the `{E_STRUCT}` path above.
					if g.table.final_sym(field.typ).kind == .struct
						&& g.global_zero_default(field.typ, 0) {
						// every field of the struct defaults to zero: memset, not a
						// stack temporary of the whole struct (cx-home/v#32)
						init += '\tmemset(&${final_c_name}, 0, sizeof(${styp})); // global 5z'
					} else if g.table.final_sym(field.typ).kind == .array_fixed {
						init += '\tmemcpy(${final_c_name}, (${styp}[]){${default_initializer}}, sizeof(${styp})); // global 5'
					} else {
						init += '\t${final_c_name} = *(${styp}*)&((${styp}[]){${default_initializer}}[0]); // global 5'
					}
				}
			}
		} else {
			def_builder.writeln('/* skip C global: ${final_c_name} */')
		}
		if needs_ending_semicolon {
			def_builder.writeln('; // global 6')
		}
		g.global_const_defs[name] = GlobalConstDef{
			mod:       node.mod
			def:       def_builder.str()
			init:      init
			dep_names: g.table.dependent_names_in_expr(field.expr)
		}
	}
}

// global_zero_default reports whether the default value of `typ` is all zero
// bytes: a number, a bool, a pointer (nil), a fixed array of such, or a V
// struct whose every field is one and whose field defaults are `0`, `false`
// or `nil`. Anything else — a string, a dynamic array, a map, an enum (its
// first value may be non-zero), an option or result, a sum type, a union, a
// field with another default — answers false, and the global keeps its
// literal initialisation (cx-home/v#32).
fn (mut g Gen) global_zero_default(typ ast.Type, depth int) bool {
	if depth > 16 || typ.has_flag(.option) || typ.has_flag(.result) || typ.has_flag(.shared_f)
		|| typ.has_flag(.atomic_f) {
		return false
	}
	if typ.is_ptr() || typ.is_pointer() || typ.is_number() || typ.is_bool() {
		return true
	}
	sym := g.table.final_sym(typ)
	match sym.info {
		ast.ArrayFixed {
			return g.global_zero_default(sym.info.elem_type, depth + 1)
		}
		ast.Struct {
			if sym.info.is_union || sym.info.is_generic || sym.language != .v {
				return false
			}
			for f in sym.info.fields {
				if f.has_default_expr && !global_zero_expr(f.default_expr) {
					return false
				}
				if !g.global_zero_default(f.typ, depth + 1) {
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

// global_zero_expr: a field default that is zero bytes — `0`, `false`, `nil`,
// `unsafe { nil }`
fn global_zero_expr(e ast.Expr) bool {
	return match e {
		ast.Nil { true }
		ast.UnsafeExpr { global_zero_expr(e.expr) }
		ast.IntegerLiteral { e.val in ['0', '0x0', '0b0', '0o0'] }
		ast.BoolLiteral { !e.val }
		else { false }
	}
}

fn (mut g Gen) sort_globals_consts() {
	util.timing_start(@METHOD)
	defer {
		util.timing_measure(@METHOD)
	}
	g.sorted_global_const_names.clear()
	mut dep_graph := depgraph.new_dep_graph()
	for var_name, var_info in g.global_const_defs {
		dep_graph.add_with_value(var_name, var_info.dep_names, var_info.order)
	}
	dep_graph_sorted := dep_graph.resolve()
	for order in [-1, 0] {
		for node in dep_graph_sorted.nodes {
			if node.value == order {
				g.sorted_global_const_names << node.name
			}
		}
	}
}

// const_array_is_static reports whether a (non-fixed) const array literal can live in static C
// data: every element a literal of a number, bool, char/rune or (V) string element type, no
// len/cap/init fields, no update expr, a C compiler that takes `_SINIT` in a static initializer.
fn (mut g Gen) const_array_is_static(node ast.ArrayInit) bool {
	if node.exprs.len == 0 || node.has_len || node.has_cap || node.has_init || node.has_index
		|| node.has_update_expr || g.is_cc_msvc || g.pref.build_mode == .build_module {
		return false
	}
	if node.elem_type.has_option_or_result() || node.elem_type.is_ptr()
		|| node.elem_type.has_flag(.shared_f) {
		return false
	}
	elem_sym := g.table.final_sym(node.elem_type)
	is_str := node.elem_type == ast.string_type
	if !is_str && elem_sym.kind !in [.bool, .i8, .i16, .i32, .int, .i64, .u8, .u16, .u32, .u64,
		.f32, .f64, .char, .rune, .isize, .usize] {
		return false
	}
	for e in node.exprs {
		match e {
			ast.StringLiteral {
				if !is_str || e.language != .v {
					return false
				}
			}
			else {
				if is_str || !const_array_number_literal(e) {
					return false
				}
			}
		}
	}
	return true
}

// const_array_number_literal: `5`, `-4`, `1.5`, `true`, `` `a` ``, `u32(7)`, `-u32(7)`.
fn const_array_number_literal(e ast.Expr) bool {
	return match e {
		ast.IntegerLiteral, ast.FloatLiteral, ast.BoolLiteral, ast.CharLiteral { true }
		ast.PrefixExpr { e.op == .minus && const_array_number_literal(e.right) }
		ast.CastExpr { e.expr is ast.IntegerLiteral || e.expr is ast.FloatLiteral }
		ast.ParExpr { const_array_number_literal(e.expr) }
		else { false }
	}
}
