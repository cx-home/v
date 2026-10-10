// xfree.v — cross-thread explicit free under the collector (cx-home/v#26).
//
// T producers allocate 48/96/200-byte scan records of the same classes, keep a
// rolling window of their own (re-verified every 64 steps) and hand every other
// record over a channel to T/2 consumers, which verify each record and free it
// explicitly. A collector thread forces gc_collect every 2 ms.
//
// The consumers never allocate: popping a channel, comparing checksums and
// free() carve nothing. Before the fix a spawned thread registered with the
// collector only at its first allocation, so these consumers ran the whole
// program OUTSIDE the stop-the-world — not in the park-wait target, never
// mach-suspended, stack and registers never scanned, their frees racing mark
// and sweep. A message a consumer held across a collection (its ring slot
// already rewritten) was rooted by nothing the collector saw: its three
// records were swept while live, handed out again, and the consumer's free()
// then cleared a live object's alloc bit — the slot was handed out twice and
// the corruption cascaded into the producers' windows.
//
// Knobs (environment): T producers (consumers = T/2), STEPS per producer,
// HOLD_EVERY/HOLD_US: each consumer holds its HOLD_EVERY-th message for HOLD_US
// microseconds before verifying it (a deschedule under load, made deterministic),
// NOFREE=1 (no explicit frees), NOGC=1 (no forced collections).
// Prints one `HOLD c<i> idx=<cache idx> ...` line per consumer that held
// (idx -1 = the thread was never registered) and the summary line; exit 1 on
// any checksum mismatch.
module main

import os
import time

__global bad_cons = int(0)
__global bad_kind = [4]int{}
__global hold_done = [64]bool{}
__global hold_idx = [64]int{}
__global hold_idok = [64]bool{}
__global hold_cyc = [64]u64{}

struct Rec {
mut:
	id  u64
	a   u64
	b   u64
	pad [3]u64
}

struct Rec2 {
mut:
	id  u64
	a   u64
	b   u64
	pad [9]u64
}

struct Rec3 {
mut:
	id  u64
	a   u64
	b   u64
	pad [22]u64
}

fn chk(id u64, a u64, b u64) bool {
	return a == id * 7 + 1 && b == id ^ 0xdeadbeefcafe
}

struct Msg {
	k  int
	p1 &Rec
	p2 &Rec2
	p3 &Rec3
	id u64
}

fn producer(t int, steps int, ch chan Msg, bad &int) {
	mut win1 := []&Rec{len: 512, init: unsafe { nil }}
	mut win2 := []&Rec2{len: 512, init: unsafe { nil }}
	mut win3 := []&Rec3{len: 512, init: unsafe { nil }}
	mut ids := []u64{len: 512}
	for s in 0 .. steps {
		id := u64(t) << 40 | u64(s)
		r1 := &Rec{
			id: id
			a:  id * 7 + 1
			b:  id ^ 0xdeadbeefcafe
		}
		r2 := &Rec2{
			id: id
			a:  id * 7 + 1
			b:  id ^ 0xdeadbeefcafe
		}
		r3 := &Rec3{
			id: id
			a:  id * 7 + 1
			b:  id ^ 0xdeadbeefcafe
		}
		if s % 2 == 0 {
			ch <- Msg{
				k:  1
				p1: r1
				p2: r2
				p3: r3
				id: id
			}
		} else {
			w := s % 512
			win1[w] = r1
			win2[w] = r2
			win3[w] = r3
			ids[w] = id
		}
		if s % 64 == 1 {
			for w in 0 .. 512 {
				if win1[w] == unsafe { nil } {
					continue
				}
				i := ids[w]
				if win1[w].id != i || !chk(i, win1[w].a, win1[w].b) || win2[w].id != i
					|| !chk(i, win2[w].a, win2[w].b) || win3[w].id != i
					|| !chk(i, win3[w].a, win3[w].b) {
					unsafe {
						(*bad)++
					}
				}
			}
		}
	}
}

// consumer allocates nothing: every value it touches is on its stack or was
// allocated by a producer. (The environment is read in main for that reason —
// os.getenv of a set variable allocates the value string.)
fn consumer(ci int, ch chan Msg, bad &int, done chan int, nofree bool, hold_every int, hold_us int) {
	mut n := 0
	for {
		m := <-ch or { break }
		if hold_every > 0 && !hold_done[ci] && n == hold_every {
			// hold the popped message across collections; once the ring slot it
			// came from is rewritten, this frame is the records' only root
			c0 := gc_cycles()
			time.sleep(hold_us * time.microsecond)
			hold_cyc[ci] = gc_cycles() - c0
			hold_idok[ci] = m.p1.id == m.id && m.p2.id == m.id && m.p3.id == m.id
			i, _, _ := vgc_my_stack_info()
			hold_idx[ci] = i
			hold_done[ci] = true
		}
		if m.p1.id != m.id || !chk(m.id, m.p1.a, m.p1.b) || m.p2.id != m.id
			|| !chk(m.id, m.p2.a, m.p2.b) || m.p3.id != m.id || !chk(m.id, m.p3.a, m.p3.b) {
			unsafe {
				(*bad)++
			}
			bad_cons++
			if m.p1.id != m.id || !chk(m.id, m.p1.a, m.p1.b) {
				bad_kind[1]++
			}
			if m.p2.id != m.id || !chk(m.id, m.p2.a, m.p2.b) {
				bad_kind[2]++
			}
			if m.p3.id != m.id || !chk(m.id, m.p3.a, m.p3.b) {
				bad_kind[3]++
			}
		}
		if !nofree {
			unsafe {
				free(m.p1)
				free(m.p2)
				free(m.p3)
			}
		}
		n++
	}
	done <- n
}

fn collector(stop &bool) {
	if os.getenv('NOGC') != '' {
		return
	}
	for !*stop {
		gc_collect()
		time.sleep(2 * time.millisecond)
	}
}

fn main() {
	t := os.getenv_opt('T') or { '8' }.int()
	steps := os.getenv_opt('STEPS') or { '200000' }.int()
	nofree := os.getenv('NOFREE') != ''
	hold_every := os.getenv_opt('HOLD_EVERY') or { '0' }.int()
	hold_us := os.getenv_opt('HOLD_US') or { '0' }.int()
	ch := chan Msg{cap: 4096}
	done := chan int{cap: 64}
	mut bad := 0
	mut stop := false
	c := spawn collector(&stop)
	nc := if t / 2 > 0 { t / 2 } else { 1 }
	for ci in 0 .. nc {
		spawn consumer(ci, ch, &bad, done, nofree, hold_every, hold_us)
	}
	mut ps := []thread{}
	for i in 0 .. t {
		ps << spawn producer(i, steps, ch, &bad)
	}
	ps.wait()
	ch.close()
	mut freed := 0
	for _ in 0 .. nc {
		freed += <-done
	}
	stop = true
	c.wait()
	for ci in 0 .. nc {
		if hold_done[ci] {
			println('HOLD c${ci} idx=${hold_idx[ci]} cycles=${hold_cyc[ci]} id_ok=${hold_idok[ci]}')
		}
	}
	println('xfree T=${t} producers steps=${steps} consumers=${nc} freed=${freed} bad=${bad} bad_at_consumer=${bad_cons} kinds48/96/200=${bad_kind[1]}/${bad_kind[2]}/${bad_kind[3]}')
	if bad != 0 {
		exit(1)
	}
}
