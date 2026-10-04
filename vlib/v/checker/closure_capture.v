// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module checker

import os
import v.ast

// MutCaptureWrite is how a statement inside a closure writes an expression.
enum MutCaptureWrite {
	rebind // `x = v`, `x += v`, `x++`: the expression itself is replaced
	mutate // `x << v`, `x.m()` with a `mut` receiver, `f(mut x)`: changed in place
	buffer // an array's `sort`, `sort_with_compare`, `reverse_in_place`, `reset`: only the shared buffer is written
}

// check_mut_capture_write reports a write that a `[mut x]` closure capture
// makes to its own COPY of `x`, which therefore never reaches the `x` outside
// the closure. V captures by value: `[mut x]` only makes the closure's copy
// mutable (docs.md, Closures), so the write is lost without a word. The
// check is exact on the expression's types:
//   - a capture of a `mut` parameter is a reference and is never reported;
//   - a write below a reference (a field of a pointer, a `shared` field, an element of an array
//     or a string, a smartcast sum type or interface variant) reaches the
//     shared object and is never reported;
//   - rebinding the captured name itself is lost for every type, a pointer too;
//   - an in-place change (`<<`, a `mut` receiver, a `mut` argument) is lost
//     for a value and not for a pointer; `sort`, `reverse_in_place` or `reset`
//     on an array writes only the buffer the copy shares and is not reported
//     (a fixed array is a value: the same call on its copy is lost, reported).
// Only C-backend code outside vlib is checked (vlib keeps V's semantics);
// checker test files (`.vv`) are checked so the diagnostic has its fixture.
fn (mut c Checker) check_mut_capture_write(expr ast.Expr, kind MutCaptureWrite) {
	if !c.inside_anon_fn || c.cur_anon_fn == unsafe { nil } || c.cur_anon_fn.inherited_vars.len == 0 {
		return
	}
	if !c.mut_capture_check_applies() {
		return
	}
	top_typ := c.mut_capture_expr_type(expr)
	if kind != .rebind && (top_typ == 0 || top_typ.is_ptr() || top_typ.has_flag(.shared_f)) {
		return
	}
	if kind == .buffer && c.table.final_sym(top_typ).kind == .array {
		return
	}
	root := c.mut_capture_write_root(expr) or { return }
	mut is_mut_capture := false
	for v in c.cur_anon_fn.inherited_vars {
		if v.name == root.name {
			is_mut_capture = v.is_mut
			break
		}
	}
	if !is_mut_capture {
		return
	}
	captured := c.cur_anon_fn.decl.scope.find_var(root.name) or { return }
	if captured.is_auto_deref || captured.typ.has_flag(.shared_f)
		|| captured.typ.has_flag(.atomic_f) {
		return
	}
	c.error('`${root.name}` is captured by value: `[mut ${root.name}]` gives the closure its own copy, so this write never reaches the `${root.name}` outside it; capture a reference instead (`mut r := &${root.name}` before the closure, then `[mut r]`)',
		expr.pos())
}

// mut_capture_check_applies is true for the C backend outside vlib, and for
// checker test files. The JavaScript backends capture a `mut` name by
// reference (gen/js copies only the immutable captures), so nothing is lost there.
fn (c &Checker) mut_capture_check_applies() bool {
	if c.pref.backend != .c || c.file == unsafe { nil } {
		return false
	}
	path := c.file.path
	if path.ends_with('.vv') || !path.contains('vlib') {
		return true
	}
	vlib := os.real_path(os.join_path(c.pref.vroot, 'vlib'))
	return !os.real_path(path).starts_with(vlib + os.path_separator)
}

// mut_capture_write_root follows a written expression down to the name it
// writes, through value containers only; it stops (none) at a reference.
fn (c &Checker) mut_capture_write_root(expr ast.Expr) ?ast.Ident {
	match expr {
		ast.Ident {
			return expr
		}
		ast.ParExpr {
			return c.mut_capture_write_root(expr.expr)
		}
		ast.SelectorExpr {
			if expr.expr_type == 0 || expr.expr_type.is_ptr() || expr.typ.has_flag(.shared_f) {
				return none
			}
			match c.table.final_sym(expr.expr_type).kind {
				.interface, .sum_type {
					return none
				}
				else {}
			}

			if expr.expr is ast.Ident {
				if expr.expr.obj is ast.Var {
					// a smartcast variant of a sum type or an interface is
					// reached through the variant pointer the value holds
					if expr.expr.obj.smartcasts.len > 0 {
						return none
					}
				}
			}
			return c.mut_capture_write_root(expr.expr)
		}
		ast.IndexExpr {
			if expr.left_type == 0 || expr.left_type.is_ptr() {
				return none
			}
			match c.table.final_sym(expr.left_type).kind {
				.map, .array_fixed {
					return c.mut_capture_write_root(expr.left)
				}
				else {
					// an array's or a string's elements live in a buffer the
					// copy shares with the original
					return none
				}
			}
		}
		else {
			return none
		}
	}
}

// mut_capture_expr_type is the type of a written expression, 0 when unknown.
fn (c &Checker) mut_capture_expr_type(expr ast.Expr) ast.Type {
	match expr {
		ast.Ident {
			if expr.obj is ast.Var {
				return expr.obj.typ
			}
			if c.cur_anon_fn != unsafe { nil } {
				if v := c.cur_anon_fn.decl.scope.find_var(expr.name) {
					return v.typ
				}
			}
			return 0
		}
		ast.ParExpr {
			return c.mut_capture_expr_type(expr.expr)
		}
		ast.SelectorExpr {
			return expr.typ
		}
		ast.IndexExpr {
			return expr.typ
		}
		else {
			return 0
		}
	}
}
