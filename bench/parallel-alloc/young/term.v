// term.v — one allocating thread's term (cx-home/v#56, `-gc e`; vgc_one_thread_term in
// vlib/builtin/vgc_d_vgc.c.v). A 2 MB list of 48-byte nodes is kept live, a full cycle
// runs, and the program prints the heap in use after it (USE=) and the goal that cycle
// set (GOAL=, vgc_full_goal_probe): the goal less the use is the term the pacer gave one
// allocating thread for a marked set of this size — a quarter of it at the default,
// half under VGC_ONE_THREAD_PCT=50, all of it under 100 (Go's pacing).
module main

const live_bytes = 2 * 1024 * 1024

struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [5]u64
}

fn main() {
	mut head := &Node(unsafe { nil })
	for i in 0 .. live_bytes / 48 {
		mut n := &Node{
			next: head
		}
		n.pad[0] = u64(i)
		head = n
	}
	gc_collect()
	use := gc_memory_use()
	goal := vgc_full_goal_probe()
	mut kept := 0
	for n := head; n != unsafe { nil }; n = n.next {
		kept++
	}
	println('USE=${use} GOAL=${goal} kept=${kept}')
}
