// DEBUG cx-private#1887 (not for merge): threads that allocate enough to collect.
#include "@VMODROOT/ci/dbg1887.h"

fn C.dbg1887_install()

fn worker(id int) int {
	mut total := 0
	mut keep := []string{}
	for i in 0 .. 200000 {
		s := 'x'.repeat(i % 64 + 1) + id.str()
		total += s.len
		if i % 1000 == 0 {
			keep << s
		}
	}
	eprintln('worker ${id} done ${total} kept ${keep.len}')
	return total
}

fn main() {
	C.dbg1887_install()
	mut ths := []thread int{}
	for i in 0 .. 8 {
		ths << spawn worker(i)
	}
	r := ths.wait()
	println('dbg_1887 ok ${r.len}')
}
