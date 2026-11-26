// cx-private#2052 (k-nucleotide's mode B: the idle sized pool past the goal) —
// SIZED runs dropped before a program's last collections must leave the
// resident set in the next collection when the committed pages are past the
// goal, as an oversized span does (vgc_oversized_last_cycle_test).
//
// vgc_pool_trim takes a sized run only once it is vgc_pool_trim_age (2) cycles
// old. k-nucleotide 25 M ends with 71-88 MB of hot plain + small runs to exit
// (dev2 pooldiag, native-time DELTA 26): its last cycles come too close
// together for the age gate. Past the goal the age gate costs resident pages
// the program has already shown it does not need; under the goal it stays
// (the recommit cost of g_churn, vgc_pool_trim_all's comment).
//
// The test warms a small-object churn, then drops 150 MB in 600 buffers of
// 256 KB (sized runs, not oversized), keeps churning until TWO natural
// collections have completed after the drop (never gc_collect(), which returns
// the whole pool), and reads gc_heap_usage().unmapped_bytes: it must have grown
// by at least half the dropped bytes.
module main

const mb = 1024 * 1024
const piece_len = 256 * 1024
const pieces = 600
const big_len = pieces * piece_len
const keep_len = 24 * mb

struct Node {
	next &Node = unsafe { nil }
	pad  [6]u64
}

// churn drops n chains of 256 64-byte nodes (garbage only the collector finds;
// the RC front line frees a lone buffer at once, never a chain's tail)
fn churn(n int, salt int) u64 {
	mut s := u64(0)
	for _ in 0 .. n {
		mut head := &Node(unsafe { nil })
		for _ in 0 .. 256 {
			head = &Node{
				next: head
			}
		}
		s += u64(salt)
		s += head.pad[0]
	}
	return s
}

// hold_big touches pieces buffers of piece_len and drops them on return. It
// runs on its OWN thread (hold_big_on_a_thread): the array of 600 slices left
// in a stale stack slot or callee-saved register of the test's thread kept all
// 150 MB marked (dev1: two cycles after the drop still marked 174 MB); a
// joined thread's stack is no root.
@[noinline]
fn hold_big(n int) u64 {
	mut held := [][]u8{cap: pieces}
	for i in 0 .. pieces {
		mut b := []u8{len: piece_len, init: u8(n + i)}
		b[n] = 9
		held << b
	}
	mut s := u64(0)
	for b in held {
		s += b[piece_len - 1]
	}
	return s
}

fn hold_big_on_a_thread(n int) u64 {
	t := spawn hold_big(n)
	return t.wait()
}

fn test_sized_runs_dropped_past_the_goal_leave_in_the_next_collections() {
	keep := []u8{len: keep_len, init: 7}
	mut sink := churn(4000, 1) // the small pool warm: several cycles of 64 B chains
	c0 := gc_cycles()
	sink += hold_big_on_a_thread(3)
	// the baseline at the drop. The collection that returns the buffer is the
	// first one to START after the drop: on x86 (ardec-dev3) that one already
	// completed inside churn(10) (cycle 11); on arm64 the cycle completing
	// there was in flight at the drop, and the next one returns it (cycle 12).
	// So: up to two completed collections after the drop, and the highest
	// unmapped reading in that window (later churn re-commits a few pages).
	c1 := gc_cycles()
	un0 := gc_heap_usage().unmapped_bytes
	mut un1 := un0
	sink += churn(10, 2)
	mut n := 0
	for {
		u := gc_heap_usage().unmapped_bytes
		if u > un1 {
			un1 = u
		}
		if gc_cycles() >= c1 + 2 || n >= 800 {
			break
		}
		sink += churn(50, n)
		n++
	}
	c2 := gc_cycles()
	returned := if un1 > un0 { un1 - un0 } else { usize(0) }
	println('vgc_sized_last_cycle: dropped=${big_len} cycles ${c0} -> ${c1} -> ${c2} (churn rounds ${n}) unmapped ${un0} -> ${un1} returned=${returned} returned_over_big=${f64(returned) / f64(big_len):.3f} keep=${keep[0]} sink=${sink}')
	assert c2 >= c1 + 2, 'two collections did not run while the churn went on'
	assert returned >= usize(big_len / 2), 'the two collections after ${big_len} bytes of sized runs were dropped returned ${returned}: the idle sized runs stayed resident past the goal (age-gated trim)'
}
