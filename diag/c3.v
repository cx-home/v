module main

// spawn T threads that allocate and exit; no forced collection
import os

fn main() {
	t := os.getenv_opt('T') or { '2' }.int()
	mut ths := []thread int{}
	for i in 0 .. t {
		ths << spawn fn (i int) int {
			mut s := []string{}
			for k in 0 .. 20000 {
				s << 'x${k}-${i}'
				if s.len > 500 {
					s = []string{}
				}
			}
			return s.len
		}(i)
	}
	r := ths.wait()
	eprintln('c3 threads done ${r.len}')
	println('c3 ok')
}
