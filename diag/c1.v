module main

fn main() {
	eprintln('c1 start')
	mut keep := []string{}
	for i in 0 .. 5 {
		keep << 'x${i}'.repeat(100)
		eprintln('c1 before gc ${i}')
		gc_collect()
		eprintln('c1 after gc ${i}')
	}
	println('c1 done ${keep.len}')
}
