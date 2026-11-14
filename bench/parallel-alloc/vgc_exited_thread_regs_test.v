// vgc_exited_thread_regs_test.v — a collection keeps nothing that only an
// exited thread's captured register file names (cx-home/cx-platform-store#74).
//
// A stop-the-world cycle captures each suspended thread's registers into its
// suspend record, and vgc_mark_roots shades them precisely (vgc_thread_regs,
// regs[0..nregs] of the records acked this cycle). It ALSO scanned every
// suspend-record chunk whole, to the high-water mark, every cycle: the records
// of threads that were not suspended in that cycle and of threads that have
// exited, and the words past nregs. A register word a thread held when it was
// last suspended stays in its record after it exits, and every later cycle
// marked what it named. store_columnar_test's live-heap bound read 0.9-2.2 MB
// over (store#74: one put-docs batch held by an exited seal thread's record,
// -d vgc_rootdiag root=suspend).
//
// Shape: a thread allocates a 1 MB buffer (a large object, its own span) and
// spins reading through the pointer until told to stop, so the pointer sits in
// a register when main's gc_collect suspends it; then it drops the buffer and
// exits. After the join no stack or register of a live thread names the
// buffer: two collections must free it (the live heap falls back to within
// 256 KB of where it was). Repeated over several threads and rounds.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_exited_thread_regs_test.v
module main

const buf_len = 1024 * 1024

@[heap]
struct Gate {
mut:
	started int
	stop    int
}

@[noinline]
fn spin_on(p &u8, mut g Gate) u64 {
	mut acc := u64(0)
	g.started = 1
	for g.stop == 0 {
		acc += unsafe { p[0] }
		acc += unsafe { p[buf_len - 1] }
	}
	return acc
}

fn holder(mut g Gate) {
	b := []u8{len: buf_len, init: 3}
	_ = spin_on(b.data, mut g)
}

fn live() u64 {
	gc_collect()
	gc_collect()
	return u64(gc_heap_usage().total_bytes)
}

fn test_an_exited_threads_saved_registers_keep_nothing() {
	mut worst := u64(0)
	for round in 0 .. 6 {
		l0 := live()
		mut gates := []&Gate{}
		mut ths := []thread{}
		for _ in 0 .. 4 {
			mut g := &Gate{}
			gates << g
			ths << spawn holder(mut g)
		}
		for g in gates {
			for g.started == 0 {
			}
		}
		// collect while the holders spin: each is suspended with its pointer in a register
		gc_collect()
		gc_collect()
		for mut g in gates {
			g.stop = 1
		}
		ths.wait()
		gates.clear()
		l1 := live()
		grew := if l1 > l0 { l1 - l0 } else { u64(0) }
		if grew > worst {
			worst = grew
		}
		eprintln('round ${round}: live ${l0} -> ${l1} (+${grew})')
	}
	assert worst < 256 * 1024, 'an exited holder kept its 1 MB buffer: the live heap stayed ${worst} bytes up after its join'
}
