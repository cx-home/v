// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module c

import v.util

const trace_gen_wanted_value = $d('trace_gen_wanted_value', '')

@[if trace_gen_wanted ?]
fn (mut g Gen) trace_gen_wanted_context(last_character_len int, s string) {
	last_n := g.out.last_n(last_character_len)
	eprintln('> trace_gen_wanted, last characters:\n${last_n}\n')
	eprintln("> trace_gen_wanted, found wanted cgen string `${trace_gen_wanted_value}` in generated string: \"${s}\"")
	print_backtrace()
}

@[if trace_gen_wanted ?]
fn (mut g Gen) trace_gen_wanted(s string) {
	if s.contains(trace_gen_wanted_value) {
		g.trace_gen_wanted_context(256, s)
	}
}

@[if trace_gen_wanted ?]
fn (mut g Gen) trace_gen_wanted2(s1 string, s2 string) {
	if s1.contains(trace_gen_wanted_value) || s2.contains(trace_gen_wanted_value) {
		g.trace_gen_wanted_context(256, s1 + s2)
	}
}

@[if trace_gen ?]
fn (mut g Gen) trace_gen(reason string, s string) {
	if g.file == unsafe { nil } {
		eprintln('gen file: <nil> | last_fn_c_name: ${g.last_fn_c_name:-45} | ${reason}: ${s}')
	} else {
		eprintln('gen file: ${g.file.path:-30} | last_fn_c_name: ${g.last_fn_c_name:-45} | ${reason}: ${s}')
	}
}

@[expand_simple_interpolation]
fn (mut g Gen) write(s string) {
	g.trace_gen_wanted(s)
	g.trace_gen('write', s)
	if g.indent > 0 && g.empty_line {
		g.out.write_string(util.tabs(g.indent))
	}
	g.out.write_string(s)
	g.empty_line = false
}

fn (mut g Gen) write2(s1 string, s2 string) {
	g.trace_gen_wanted2(s1, s2)
	g.trace_gen('write2 s1', s1)
	if g.indent > 0 && g.empty_line {
		g.out.write_string(util.tabs(g.indent))
	}
	g.out.write_string(s1)
	g.empty_line = false

	g.trace_gen('write2 s2', s2)
	if g.indent > 0 && g.empty_line {
		g.out.write_string(util.tabs(g.indent))
	}
	g.out.write_string(s2)
	g.empty_line = false
}

fn (mut g Gen) write_decimal(x i64) {
	g.trace_gen('write_decimal', x.str())
	if g.indent > 0 && g.empty_line {
		g.out.write_string(util.tabs(g.indent))
	}
	g.out.write_decimal(x)
	g.empty_line = false
}

fn (mut g Gen) writeln(s string) {
	g.trace_gen_wanted(s)
	g.trace_gen('writeln', s)
	if g.indent > 0 && g.empty_line {
		g.out.write_string(util.tabs(g.indent))
		// g.out_parallel[g.out_idx].write_string(util.tabs(g.indent))
	}
	// println('w len=${g.out_parallel.len}')
	g.out.writeln(s)
	// g.out_parallel[g.out_idx].writeln(s)
	g.empty_line = true
	// g.line_nr++
}

fn (mut g Gen) writeln2(s1 string, s2 string) {
	g.trace_gen_wanted2(s1, s2)
	g.trace_gen('writeln2 s1', s1)
	// expansion for s1
	if g.indent > 0 && g.empty_line {
		g.out.write_string(util.tabs(g.indent))
	}
	g.out.writeln(s1)
	g.empty_line = true

	// expansion for s2
	g.trace_gen('writeln2 s2', s2)
	if g.indent > 0 && g.empty_line {
		g.out.write_string(util.tabs(g.indent))
	}
	g.out.writeln(s2)
	g.empty_line = true
}

// Below are hacks that should be removed at some point.

fn (mut g Gen) go_back(n int) {
	g.out.go_back(n)
	// g.out_parallel[g.out_idx].go_back(n)
}

fn (mut g Gen) go_back_to(n int) {
	g.out.go_back_to(n)
	// g.out_parallel[g.out_idx].go_back_to(n)
}

@[inline]
fn (g &Gen) nth_stmt_pos(n int) int {
	return g.stmt_path_pos[g.stmt_path_pos.len - (1 + n)]
}

@[inline]
fn (mut g Gen) set_current_pos_as_last_stmt_pos() {
	g.stmt_path_pos << g.out.len
}

@[inline]
fn (mut g Gen) go_before_last_stmt() string {
	return g.cut_stmt_to(g.nth_stmt_pos(0))
}

@[inline]
fn (mut g Gen) go_before_ternary() string {
	return g.cut_stmt_to(g.nth_stmt_pos(g.inside_ternary))
}

fn (mut g Gen) insert_before_stmt(s string) {
	cur_line := g.cut_stmt_to(g.nth_stmt_pos(g.inside_ternary))
	g.writeln(s)
	g.write(cur_line)
}

// ExprStrCut is one cut of the output back to a statement start (`at`) made
// while an expr_string() was in progress, with the text it removed.
struct ExprStrCut {
	at   int
	text string
}

// cut_stmt_to cuts the output back to `pos`, the start of the current statement,
// so that C statements (temporaries) can be emitted before it; the caller then
// writes the cut text back after them. An expr_string() in progress whose start
// lies inside the cut text has its start moved by that hoist: the cut is noted,
// and end_expr_string() finds where the text went. (The saved offset otherwise
// pointed into the hoisted temporary, and the trim_space() of the text cut from
// there dropped whitespace at the boundary — when that was the space of a
// literal, `cs.join(' ')` compiled as `Array_string_join(cs, _S(""))`.)
fn (mut g Gen) cut_stmt_to(pos int) string {
	cut := g.out.cut_to(pos)
	if g.expr_str_starts.len > 0 && g.expr_str_starts.last() >= pos && cut.len > 0 {
		g.expr_str_cuts << ExprStrCut{
			at:   pos
			text: cut
		}
	}
	return cut
}

// begin_expr_string marks an expr_string() starting at `pos`; the answer is
// the index of the first statement cut that can concern it.
fn (mut g Gen) begin_expr_string(pos int) int {
	g.expr_str_starts << pos
	return g.expr_str_cuts.len
}

// end_expr_string answers where the expression that began at `start` begins
// now: each statement cut made meanwhile at or before it moved the text after
// the cut point to after the hoisted temporaries, written back trimmed; the
// start follows that text. A cut whose text was not written back verbatim
// leaves the start where it was (the behaviour before the fix).
fn (mut g Gen) end_expr_string(start int, first_cut int) int {
	g.expr_str_starts.delete_last()
	mut pos := start
	for i in first_cut .. g.expr_str_cuts.len {
		ev := g.expr_str_cuts[i]
		if ev.at > pos {
			continue
		}
		key := ev.text.trim_space()
		if key.len == 0 {
			continue
		}
		lead := ev.text.len - ev.text.trim_left(' \n\t\v\f\r').len
		tail := g.out.after(ev.at)
		idx := tail.index(key) or { continue }
		mut rel := pos - ev.at - lead
		if rel < 0 {
			rel = 0
		} else if rel > key.len {
			rel = key.len
		}
		pos = ev.at + idx + rel
	}
	if g.expr_str_starts.len == 0 {
		g.expr_str_cuts.clear()
	}
	return pos
}

fn (mut g Gen) insert_at(pos int, s string) {
	cur_line := g.cut_stmt_to(pos)
	// g.out_parallel[g.out_idx].cut_to(pos)
	g.writeln(s)
	g.write(cur_line)

	// After modifying the code in the buffer, we need to adjust the positions of the statements
	// to account for the added line of code.
	// This is necessary to ensure that autofree can properly insert string declarations
	// in the correct positions, considering the surgically made changes.
	for index, stmt_pos in g.stmt_path_pos {
		if stmt_pos >= pos {
			g.stmt_path_pos[index] += s.len + 1
		}
	}
}
