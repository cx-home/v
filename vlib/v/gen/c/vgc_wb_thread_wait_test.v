// vgc_wb_thread_wait_test.v — cx-core-code#279: the waiters of an array of
// threads (`ts.wait()` on a []thread T or a [N]thread T, and their ?T and !T
// forms) allocate the answer array and then store each joined result into its
// buffer. That store is a heap store of a value with pointers: the answer
// array lives across the joins, so a cycle during a join can make it old (a
// minor cycle's sticky mark) or scan it (a concurrent middle), and a store
// after that without the barrier sets no card and dirties no span — the
// result's young objects are reached from nothing the next cycle traces and
// are swept while the caller still reads them (cx's fused group-by: wrong sums
// under VGC_YOUNG=1). Each such store carries the barrier: the joined value
// lands in a stack temporary, then vgc_wb_gate(res.data), the store, and
// vgc_wb_gate_again(res.data), as the spawn wrapper does for its return box
// (cx-home/v#80). A result with no pointer (int) keeps the plain store.
import os

const vexe = @VEXE

const src = "struct Part {
	sums []i64
	name string
}

fn work(id int) Part {
	return Part{
		sums: []i64{len: 4, init: id}
		name: 'p\${id}'
	}
}

fn work_opt(id int) ?Part {
	if id < 0 {
		return none
	}
	return work(id)
}

fn work_res(id int) !Part {
	if id < 0 {
		return error('no')
	}
	return work(id)
}

fn num(id int) int {
	return id
}

fn main() {
	mut ts := []thread Part{}
	mut to := []thread ?Part{}
	mut tr := []thread !Part{}
	mut tn := []thread int{}
	for i in 0 .. 2 {
		ts << spawn work(i)
		to << spawn work_opt(i)
		tr << spawn work_res(i)
		tn << spawn num(i)
	}
	fa := [spawn work(0), spawn work(1)]!
	println(ts.wait())
	println(to.wait() or { []Part{} })
	println(tr.wait() or { []Part{} })
	println(tn.wait())
	println(fa.wait())
}
"

// the definition's body: the lines after the one naming the function and
// opening its brace, up to the closing one
fn fn_body(c string, name string) string {
	mut out := []string{}
	mut inside := false
	for l in c.split_into_lines() {
		if !inside {
			inside = l.contains(' ${name}(') && l.trim_space().ends_with('{')
			continue
		}
		if l == '}' {
			break
		}
		out << l
	}
	return out.join('\n')
}

fn generate(flags string) string {
	dir := os.join_path(os.vtmp_dir(), 'vgc_wb_thread_wait_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	prog := os.join_path(dir, 'w.vv')
	out := os.join_path(dir, 'w.c')
	os.write_file(prog, src) or { panic(err) }
	res :=
		os.execute('${os.quoted_path(vexe)} ${flags} -o ${os.quoted_path(out)} ${os.quoted_path(prog)}')
	assert res.exit_code == 0, res.output
	return os.read_file(out) or { panic(err) }
}

const gated_waiters = ['Array___v_thread_main__Part_wait', 'Array___v_thread__option_main__Part_wait',
	'Array___v_thread__result_main__Part_wait', 'Array_fixed___v_thread_main__Part_2_wait']

fn test_an_array_waiter_stores_a_result_with_pointers_between_two_barrier_gates() {
	c := generate('-gc e')
	for name in gated_waiters {
		body := fn_body(c, name)
		assert body.len > 0, '${name} not emitted'
		gate := body.index('vgc_wb_gate((void*)res.data);') or {
			assert false, '${name} stores a result with pointers without the barrier:\n${body}'
			return
		}
		store := body.index('res.data)[i] = vgc_wait_tmp;') or {
			assert false, '${name} does not store through the stack temporary:\n${body}'
			return
		}
		again := body.index('vgc_wb_gate_again((void*)res.data);') or {
			assert false, '${name} has no second gate after the store:\n${body}'
			return
		}
		assert gate < store && store < again, '${name}: gate, store, gate again out of order:\n${body}'
	}
	// the control: a result with no pointer keeps the plain store, no gate
	ints := fn_body(c, 'Array___v_thread_int_wait')
	assert ints.contains('((int*)res.data)[i] = __v_thread_int_wait(t);'), ints
	assert !ints.contains('vgc_wb_gate'), 'an int result gained a gate:\n${ints}'
	println('vgc_wb_thread_wait: ${gated_waiters.len} pointer-result waiters gated, the int one plain')
}

fn test_the_default_collector_keeps_the_plain_store() {
	c := generate('')
	body := fn_body(c, 'Array___v_thread_main__Part_wait')
	assert body.contains('((main__Part*)res.data)[i] = __v_thread_main__Part_wait(t);'), body
	assert !body.contains('vgc_wb_gate'), body
}
