import os

fn main() {
	os.system('procstat -v ${os.getpid()}')
	mut keep := []string{}
	for i in 0 .. 400000 {
		keep << 'x${i}'
		if keep.len > 2000 {
			keep = []string{}
		}
	}
	println('dbg_1856 ok ${keep.len}')
}
