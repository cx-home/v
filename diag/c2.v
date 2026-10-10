module main

fn main() {
	eprintln('c2 start')
	t := spawn fn () int {
		eprintln('c2 thread start')
		for i in 0 .. 3 {
			eprintln('c2 thread before gc ${i}')
			gc_collect()
			eprintln('c2 thread after gc ${i}')
		}
		return 1
	}()
	r := t.wait()
	println('c2 done ${r}')
}
