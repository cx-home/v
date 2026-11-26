// asan_child.v — the program vgc_asan_test.v builds with -fsanitize=address
// (cx-home/v#92). Four threads and main build linked lists whose only
// references sit in their own frames — some in a local array whose address
// escapes, which ASan places on its fake stack when
// detect_stack_use_after_return is on — collect between rounds, churn garbage
// so a list freed by mistake is overwritten, and check every list's sum. Exit 0
// and 'ASAN-CHILD OK' when all of it holds.
module main

@[heap]
struct Node {
mut:
	v    u64
	next &Node = unsafe { nil }
	pad  [6]u64
}

@[noinline]
fn build(n int, seed u64) &Node {
	mut head := &Node(unsafe { nil })
	for i in 0 .. n {
		head = &Node{
			v:    seed + u64(i)
			next: head
		}
	}
	return head
}

@[noinline]
fn sum(h &Node) u64 {
	mut s := u64(0)
	mut p := unsafe { h }
	for p != unsafe { nil } {
		s += p.v
		p = p.next
	}
	return s
}

fn want(n int, seed u64) u64 {
	return u64(n) * seed + u64(n) * u64(n - 1) / 2
}

// churn allocates garbage the size of the lists' nodes, so a node swept while
// still held is handed out again and written over
@[noinline]
fn churn(n int) u64 {
	mut t := u64(0)
	for i in 0 .. n {
		g := &Node{
			v: 0xdead0000 + u64(i)
		}
		t += g.v & 1
	}
	return t
}

// keep_in writes the lists into a caller's array through its address: the
// array escapes, so an ASan build with detect_stack_use_after_return puts it
// in a fake-stack frame, not on the thread's machine stack
@[noinline]
fn keep_in(mut keep [8]&Node, seed u64) {
	for k in 0 .. 8 {
		keep[k] = build(500, seed + u64(k) * 1000)
	}
}

@[noinline]
fn worker(id int, rounds int) int {
	mut bad := 0
	for r in 0 .. rounds {
		seed := u64(id) * 1_000_000 + u64(r) * 10_000
		mut keep := [8]&Node{}
		keep_in(mut keep, seed)
		local := build(2000, seed + 9000)
		churn(20_000)
		if id == 0 {
			gc_collect()
		}
		churn(20_000)
		for k in 0 .. 8 {
			if sum(keep[k]) != want(500, seed + u64(k) * 1000) {
				bad++
			}
		}
		if sum(local) != want(2000, seed + 9000) {
			bad++
		}
	}
	return bad
}

fn main() {
	rounds := 6
	mut ths := []thread int{}
	for id in 1 .. 5 {
		ths << spawn worker(id, rounds)
	}
	mut bad := worker(0, rounds)
	for t in ths {
		bad += t.wait()
	}
	for _ in 0 .. 3 {
		gc_collect()
	}
	if bad != 0 {
		eprintln('ASAN-CHILD BAD ${bad} lists changed under collection')
		exit(1)
	}
	println('ASAN-CHILD OK')
}
