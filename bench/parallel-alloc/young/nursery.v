// nursery.v — the nursery-region gate (cx-home/v#56 lever 7): a pointer
// store into a fresh young record makes no barrier call and sets no card.
// After the first full cycle (the young regime armed: the gate over the
// arenas) a warm batch of records fills the free slots the sweep left in
// their size class, then N records are allocated from fresh spans and
// chained by N-1 stores into them: under the lever every one of those
// records' page cards reads clean after the stores (the gate's first test
// skips the young range before the hint record and the card are read: the
// records' init stores set no card either) and the chain's stores count no
// call (-d vgc_wb_count, vgc_wb_calls_count; the pushes into the lists call
// the barrier directly, array.v, and are counted before); without it every
// page's card is set — the record's own init store called the barrier once
// per page, and the chain's stores read that card inline. A store of the
// chain's head into an OLD record still sets its card, and the chain
// survives a minor cycle through that old record alone (the card scanned).
// Prints `dirty=<k>/<N> calls=<chain>/<old>
// fresh=<records in the nursery>/<N>
// setup_minors=<n> minors=<n> old_card=<bool> bad=<k> chain=<n>/<N>`.
module main

@[heap]
struct Rec {
mut:
	a &Rec = unsafe { nil }
	n int
}

@[heap]
struct Churn {
mut:
	v    u64
	pad  [5]u64
	next &Churn = unsafe { nil }
}

@[noinline]
fn make(n int) &Rec {
	return &Rec{
		n: n
	}
}

@[noinline]
fn young(n int, base int) []&Rec {
	mut ys := []&Rec{cap: n}
	for i in 0 .. n {
		ys << make(base + i)
	}
	return ys
}

// warm fills the free slots the sweep left in the records' size class, and
// the span the bump was in at the stop: records are made until one lies in
// the young range (a span carved since the stop), so every record made after
// it is young in a fresh span
@[noinline]
fn warm_up() []&Rec {
	mut ws := []&Rec{cap: 8192}
	for ws.len < 8192 {
		r := make(-1000000 - ws.len)
		ws << r
		if vgc_is_young(r) {
			break
		}
	}
	return ws
}

@[noinline]
fn in_nursery(ys []&Rec) int {
	mut k := 0
	for y in ys {
		if vgc_is_young(y) {
			k++
		}
	}
	return k
}

// chain stores, into every record but the first, the record before it:
// N-1 pointer stores into fresh young records
@[noinline]
fn chain(ys []&Rec) {
	for i in 1 .. ys.len {
		mut r := ys[i]
		r.a = ys[i - 1]
	}
}

@[noinline]
fn dirty_pages(ys []&Rec) int {
	mut k := 0
	for y in ys {
		if vgc_card_dirty(y) {
			k++
		}
	}
	return k
}

@[noinline]
fn head_into(mut old Rec, y &Rec) {
	old.a = y
}

@[noinline]
fn mk(v u64) &Churn {
	return &Churn{
		v: v
	}
}

@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

fn main() {
	n := 20000
	ballast := []u8{len: 8 * 1024 * 1024} // held: the pacer's goal sits MBs above the batch, no cycle inside it
	mut old := make(-1) // born before the cycle: old at the stores
	gc_collect() // the first full cycle: the young regime armed, the gate over the arenas
	m0 := vgc_minor_cycles_count()
	mut warm := warm_up() // the free slots the sweep left in the size class, until a fresh span
	mut ys := young(n, 0) // fresh spans: young
	fresh := in_nursery(ys)
	setup_minors := vgc_minor_cycles_count() - m0
	ylo, ylen := vgc_young_range()
	first_rec := usize(ys[0])
	last_rec := usize(ys[n - 1])
	// the pushes into the lists above call the barrier directly (array.v)
	c0 := vgc_wb_calls_count()
	chain(ys)
	c1 := vgc_wb_calls_count()
	dirty := dirty_pages(ys)
	head_into(mut old, ys[n - 1])
	c2 := vgc_wb_calls_count()
	old_card := vgc_card_dirty(old)
	ys = []&Rec{}
	warm = []&Rec{}
	scrub_stack()
	m1 := vgc_minor_cycles_count()
	mut g := &Churn(unsafe { nil })
	mut steps := 0
	for vgc_minor_cycles_count() == m1 && steps < 20000 {
		for j in 0 .. 256 {
			g = mk(u64(j))
		}
		steps++
	}
	mut bad := 0
	mut cnt := 0
	mut p := old.a
	for p != unsafe { nil } {
		if p.n != n - 1 - cnt {
			bad++
		}
		cnt++
		p = p.a
	}
	println('dirty=${dirty}/${n} calls=${c1 - c0}/${c2 - c1} setup_minors=${setup_minors} minors=${vgc_minor_cycles_count() - m1} old_card=${old_card} bad=${bad} chain=${cnt}/${n} fresh=${fresh}/${n} range=${ylo}+${ylen} first=${first_rec} last_rec=${last_rec} steps=${steps} last=${g.v} warm=${warm.len} ballast=${ballast.len}')
}
