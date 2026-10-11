// vinit.v — a module initialiser's objects stay in the collector's world
// (cx-home/v#27: the webhook-saga door on fix/fable-v116).
//
// V's _vinit zero-assigns the vgc_heap global AFTER builtin_init's first
// allocations registered the main thread (the heap-init ordering quirk; vgc_init
// runs after _vinit). The arena table, the span registry and the per-thread
// slot table all sat inside vgc_heap, so the zeroing wiped main's cache with
// the rest and main refilled from the re-created arena. With the slot table in
// C-side chunks, main's slot survived the zeroing with its spans — spans of the
// WIPED arena — and every object a module's init() allocated was carved from
// memory the collector no longer knew: pointers to it shade nothing, it is
// never scanned, and what is reachable only through it (this holder's grown
// map backing, its items array) is swept while live.
//
//   ./v -gc e -d cx_envcheck run vinit.v     prints ' ok '; exit 3 on a loss
@[has_globals]
module main

struct Holder {
mut:
	m     map[string]int
	items []string
}

// The window's first allocations are builtin's HEAP consts (error_sentinel,
// none__: 16- and 32-byte conservatively scanned objects), so the stale spans
// are theirs: cells of those classes land in them. A cell is the only path to
// its holder; a holder's grown backings are reachable only through it.
struct Cell16 {
mut:
	h   &Holder = unsafe { nil }
	pad usize
}

struct Cell24 {
mut:
	h   &Holder = unsafe { nil }
	pad [2]usize
}

struct Cell32 {
mut:
	h   &Holder = unsafe { nil }
	pad [3]usize
}

struct Cell48 {
mut:
	h   &Holder = unsafe { nil }
	pad [5]usize
}

struct Cell64 {
mut:
	h   &Holder = unsafe { nil }
	pad [7]usize
}

__global (
	g_c16 &Cell16
	g_c24 &Cell24
	g_c32 &Cell32
	g_c48 &Cell48
	g_c64 &Cell64
)

fn new_holder() &Holder {
	mut h := &Holder{}
	for i in 0 .. 64 {
		k := 'init-${i}'
		h.m[k] = i
		h.items << k
	}
	return h
}

// init runs inside _vinit, after vgc_heap's zero-assignment and before vgc_init:
// the cells and their holders are the window's allocations.
fn init() {
	g_c16 = &Cell16{
		h: new_holder()
	}
	g_c24 = &Cell24{
		h: new_holder()
	}
	g_c32 = &Cell32{
		h: new_holder()
	}
	g_c48 = &Cell48{
		h: new_holder()
	}
	g_c64 = &Cell64{
		h: new_holder()
	}
}

fn holders() []&Holder {
	return [g_c16.h, g_c24.h, g_c32.h, g_c48.h, g_c64.h]
}

const n = 20000

// grow adds n entries to the holder's map and array past their init-time
// capacity: the new backings live in the arena the collector knows, reachable
// only through the holder (and the data-segment global that points at it).
@[noinline]
fn grow() {
	for mut h in holders() {
		for i in 0 .. n {
			k := 'main-${i}'
			h.m[k] = i
			h.items << k
		}
	}
}

// clobber overwrites the stack region grow's frames used, so no stale
// temporary (a backing pointer left in a dead slot) roots them conservatively.
@[noinline]
fn clobber(depth int) usize {
	mut pad := [4096]usize{}
	for i in 0 .. 4096 {
		pad[i] = usize(i)
	}
	if depth > 0 {
		return clobber(depth - 1) + pad[depth]
	}
	return pad[1]
}

fn main() {
	grow()
	_ = clobber(4)
	gc_collect()
	// Churn, so freed backings are reused before the check reads them.
	mut junk := []string{}
	for i in 0 .. 200000 {
		junk << 'junk-${i}'.repeat(3)
		if junk.len > 4096 {
			junk.clear()
		}
	}
	_ = clobber(4)
	gc_collect()
	mut bad := 0
	mut lost := 0
	for ci, h in holders() {
		st := vgc_map_backing_status(unsafe { &h.m })
		if (st & 1) == 0 || ((st >> 8) & 1) == 0 {
			lost++
		}
		mut hb := 0
		for i in 0 .. n {
			k := 'main-${i}'
			v := h.m[k] or { -1 }
			if v != i {
				hb++
			}
			if h.items[64 + i] != k {
				hb++
			}
		}
		println('vinit-window cell=${ci} backing=0x${st:x} bad=${hb} len=${h.m.len}')
		bad += hb
	}
	if bad != 0 || lost != 0 {
		println('a module initialiser object lost its referents to a collection (lost=${lost} bad=${bad})')
		exit(3)
	}
	println(' ok ')
}
