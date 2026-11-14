// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module checker

import v.ast

// HeapParamScan decides whether a by-value receiver or parameter of a @[heap]
// struct needs its heap copy (cgen's `T* p = HEAP(T, _v_toheap_p);` on every
// call). The copy exists so that the parameter's address stays valid after the
// call returns: `&p`, a pointer-receiver method on `p`, `p` passed or stored on.
// A body that only reads the parameter's fields — `p.name`, `p.meta.anchor`,
// `p.kids[i]`, `for x in p.kids` — never takes its address, so the copy is
// pure cost (cx's Element accessors copied the whole Element on each call,
// cx-home/cx-core-data#97). The scan is syntactic and conservative: any use of
// the name other than a field read whose field holds a pointer, a scalar, a
// string, an array, a map or an option of those, and any node kind the scan
// does not list, keeps the copy.
struct HeapParamScan {
	table &ast.Table
	sym   &ast.TypeSymbol
	name  string
mut:
	needs_copy bool
}

fn (mut c Checker) heap_param_needs_copy(stmts []ast.Stmt, name string, sym &ast.TypeSymbol) bool {
	if name == '' || name == '_' {
		return false
	}
	mut s := HeapParamScan{
		table: c.table
		sym:   unsafe { sym }
		name:  name
	}
	s.stmts(stmts)
	return s.needs_copy
}

fn (s &HeapParamScan) field_read_is_plain(field_name string) bool {
	field := s.table.find_field_with_embeds(s.sym, field_name) or { return false }
	mut typ := field.typ
	if typ.has_flag(.generic) || typ.has_flag(.shared_f) || typ.has_flag(.atomic_f) {
		return false
	}
	if typ.is_any_kind_of_pointer() {
		return true
	}
	if typ.has_flag(.result) {
		return false
	}
	typ = typ.clear_flag(.option)
	if typ.is_any_kind_of_pointer() {
		return true
	}
	fsym := s.table.final_sym(typ)
	return match fsym.kind {
		.i8, .i16, .i32, .int, .i64, .isize, .u8, .u16, .u32, .u64, .usize, .f32, .f64, .bool,
		.char, .rune, .enum, .string, .array, .map, .voidptr, .byteptr, .charptr {
			true
		}
		else {
			false
		}
	}
}

fn (mut s HeapParamScan) stmts(stmts []ast.Stmt) {
	for stmt in stmts {
		if s.needs_copy {
			return
		}
		s.stmt(stmt)
	}
}

fn (mut s HeapParamScan) stmt(stmt ast.Stmt) {
	match stmt {
		ast.ExprStmt {
			s.expr(stmt.expr)
		}
		ast.Return {
			s.exprs(stmt.exprs)
		}
		ast.AssignStmt {
			s.exprs(stmt.left)
			s.exprs(stmt.right)
		}
		ast.Block {
			s.stmts(stmt.stmts)
		}
		ast.ForStmt {
			s.expr(stmt.cond)
			s.stmts(stmt.stmts)
		}
		ast.ForInStmt {
			if stmt.key_var == s.name || stmt.val_var == s.name || stmt.val_is_ref {
				s.needs_copy = true
				return
			}
			s.expr(stmt.cond)
			s.expr(stmt.high)
			s.stmts(stmt.stmts)
		}
		ast.ForCStmt {
			if stmt.has_init {
				s.stmt(stmt.init)
			}
			s.expr(stmt.cond)
			if stmt.has_inc {
				s.stmt(stmt.inc)
			}
			s.stmts(stmt.stmts)
		}
		ast.AssertStmt {
			s.expr(stmt.expr)
			s.expr(stmt.extra)
		}
		ast.BranchStmt, ast.EmptyStmt {}
		else {
			s.needs_copy = true
		}
	}
}

fn (mut s HeapParamScan) exprs(exprs []ast.Expr) {
	for e in exprs {
		if s.needs_copy {
			return
		}
		s.expr(e)
	}
}

fn (mut s HeapParamScan) or_block(o ast.OrExpr) {
	s.stmts(o.stmts)
}

fn (mut s HeapParamScan) expr(expr ast.Expr) {
	if s.needs_copy {
		return
	}
	match expr {
		ast.Ident {
			if expr.name == s.name {
				s.needs_copy = true
			}
		}
		ast.SelectorExpr {
			if expr.expr is ast.Ident && expr.expr.name == s.name {
				if !s.field_read_is_plain(expr.field_name) {
					s.needs_copy = true
				}
			} else {
				s.expr(expr.expr)
			}
			s.or_block(expr.or_block)
		}
		ast.PrefixExpr {
			if expr.op == .amp {
				// `&p`, `&p.f`, `&p.f[i]`: an address into the parameter
				mut base := expr.right
				for {
					match base {
						ast.SelectorExpr { base = base.expr }
						ast.IndexExpr { base = base.left }
						ast.ParExpr { base = base.expr }
						else { break }
					}
				}
				if base is ast.Ident && base.name == s.name {
					s.needs_copy = true
					return
				}
			}
			s.expr(expr.right)
			s.or_block(expr.or_block)
		}
		ast.InfixExpr {
			s.expr(expr.left)
			s.expr(expr.right)
			s.or_block(expr.or_block)
		}
		ast.PostfixExpr {
			s.expr(expr.expr)
		}
		ast.ParExpr {
			s.expr(expr.expr)
		}
		ast.UnsafeExpr {
			s.expr(expr.expr)
		}
		ast.CastExpr {
			s.expr(expr.expr)
			s.expr(expr.arg)
		}
		ast.AsCast {
			s.expr(expr.expr)
		}
		ast.IndexExpr {
			s.expr(expr.left)
			s.expr(expr.index)
			s.exprs(expr.indices)
			s.or_block(expr.or_expr)
		}
		ast.RangeExpr {
			s.expr(expr.low)
			s.expr(expr.high)
		}
		ast.CallExpr {
			s.expr(expr.left)
			for arg in expr.args {
				s.expr(arg.expr)
			}
			s.or_block(expr.or_block)
		}
		ast.IfExpr {
			if expr.is_comptime {
				s.needs_copy = true
				return
			}
			for branch in expr.branches {
				s.expr(branch.cond)
				s.stmts(branch.stmts)
			}
		}
		ast.IfGuardExpr {
			for v in expr.vars {
				if v.name == s.name {
					s.needs_copy = true
					return
				}
			}
			s.expr(expr.expr)
		}
		ast.MatchExpr {
			if expr.is_comptime {
				s.needs_copy = true
				return
			}
			s.expr(expr.cond)
			for branch in expr.branches {
				s.exprs(branch.exprs)
				s.stmts(branch.stmts)
			}
		}
		ast.StringInterLiteral {
			s.exprs(expr.exprs)
			s.exprs(expr.fwidth_exprs)
			s.exprs(expr.precision_exprs)
		}
		ast.ArrayInit {
			s.exprs(expr.exprs)
			s.expr(expr.len_expr)
			s.expr(expr.cap_expr)
			s.expr(expr.init_expr)
			s.expr(expr.update_expr)
		}
		ast.IntegerLiteral, ast.FloatLiteral, ast.StringLiteral, ast.BoolLiteral, ast.CharLiteral,
		ast.None, ast.Nil, ast.EmptyExpr, ast.NodeError, ast.EnumVal, ast.TypeNode {}
		else {
			s.needs_copy = true
		}
	}
}
