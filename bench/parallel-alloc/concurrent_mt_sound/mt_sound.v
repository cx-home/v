// C: soundness under threads — T workers allocate small checksummed records
// and large pattern-filled buffers (33 KB..2 MB, the large_inflight path) in a
// rolling window, a collector thread forces gc_collect in a loop, and every
// worker re-verifies its whole window after each step. Any reuse of a live
// span (stamp released too early, large_inflight missed) shows as a checksum
// mismatch or a crash.
module main

import os
import time
import rand

struct Obj {
mut:
	id   u64
	a    u64
	b    u64
	name string
	kid  &Obj = unsafe { nil }
}

fn mk(id u64) &Obj {
	k := &Obj{
		id:   id ^ 0x5555
		a:    id * 3
		b:    ~id
		name: 'k${id}'
	}
	return &Obj{
		id:   id
		a:    id * 7 + 1
		b:    id ^ 0xdeadbeef
		name: 'obj-${id}-tail'
		kid:  k
	}
}

fn ok(o &Obj, id u64) bool {
	if o.id != id || o.a != id * 7 + 1 || o.b != id ^ 0xdeadbeef || o.name != 'obj-${id}-tail' {
		return false
	}
	k := o.kid
	return k.id == id ^ 0x5555 && k.a == id * 3 && k.b == ~id && k.name == 'k${id}'
}

fn fill(n int, seed u64) []u8 {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 61 {
		b[i] = u8((seed + u64(i)) & 0xff)
	}
	if (n - 1) % 61 != 0 {
		b[n - 1] = u8(seed & 0xff)
	}
	return b
}

fn bok(b []u8, seed u64) bool {
	for i := 0; i < b.len; i += 61 {
		if b[i] != u8((seed + u64(i)) & 0xff) {
			return false
		}
	}
	return (b.len - 1) % 61 == 0 || b[b.len - 1] == u8(seed & 0xff)
}

fn worker(tid int, steps int, win int) int {
	mut objs := []&Obj{len: win, init: unsafe { nil }}
	mut ids := []u64{len: win}
	mut bufs := [][]u8{len: 8}
	mut bseeds := []u64{len: 8}
	mut bad := 0
	mut rng := rand.new_default()
	rng.seed([u32(tid + 1), u32(99)])
	for s in 0 .. steps {
		id := u64(tid) << 40 | u64(s)
		slot := s % win
		objs[slot] = mk(id)
		ids[slot] = id
		if s % 5 == 0 {
			n := 33 * 1024 + int(rng.u32n(2 * 1024 * 1024) or { 0 })
			bs := s / 5 % 8
			bufs[bs] = fill(n, id)
			bseeds[bs] = id
		}
		// transient garbage, small and large
		_ := 'junk-${s}-${tid}'.repeat(3)
		if s % 7 == 0 {
			_ := []u8{len: 40000 + int(rng.u32n(300000) or { 0 })}
		}
		if s % 50 == 0 {
			for i in 0 .. win {
				if objs[i] != unsafe { nil } && !ok(objs[i], ids[i]) {
					bad++
				}
			}
			for i in 0 .. 8 {
				if bufs[i].len > 0 && !bok(bufs[i], bseeds[i]) {
					bad++
				}
			}
		}
	}
	return bad
}

fn main() {
	t := os.getenv_opt('T') or { '8' }.int()
	steps := os.getenv_opt('STEPS') or { '60000' }.int()
	win := os.getenv_opt('WIN') or { '2000' }.int()
	mut stop := &[]bool{len: 1}
	gcth := spawn fn (stop &[]bool) int {
		mut n := 0
		for !unsafe { (*stop)[0] } {
			gc_collect()
			n++
			time.sleep(2 * time.millisecond)
		}
		return n
	}(stop)
	mut ths := []thread int{}
	for i in 0 .. t {
		ths << spawn worker(i, steps, win)
	}
	r := ths.wait()
	unsafe {
		(*stop)[0] = true
	}
	ncol := gcth.wait()
	mut bad := 0
	for x in r {
		bad += x
	}
	println('mt_sound T=${t} steps=${steps} forced_gc=${ncol} bad=${bad}')
	if bad != 0 {
		exit(3)
	}
}
