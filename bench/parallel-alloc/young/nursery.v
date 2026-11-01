// nursery.v — the nursery-region gate (cx-home/v#56 lever 7): a pointer
// store into a fresh young record makes no barrier call and sets no card.
// After the first full cycle (the young regime armed: the gate over the
// arenas) a warm batch of records fills the free slots the sweep left in
// their size class, then N records are allocated from fresh spans and
// chained by N-1 stores into them: under the lever every one of those
// records' page cards reads clean after the stores (the gate's first test
// skips the young range before the hint record and the card are read) and
// the stores count no call (-d vgc_wb_count, vgc_wb_calls_count); without
// it every page's card is set — the record's own init store called the
// barrier once per page, and the chain's stores read that card inline. A
// store of the chain's head into an OLD record still sets its card, and
// the chain survives a minor cycle through that old record alone (the card
// scanned). Prints `dirty=<k>/<N> calls=<young+chain>/<old>
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
	mut old := make(-1) // born before the cycle: old at the stores
	gc_collect() // the first full cycle: the young regime armed, the gate over the arenas
	m0 := vgc_minor_cycles_count()
	c0 := vgc_wb_calls_count()
	mut warm := young(5000, -1000000) // the free slots the sweep left in the size class
	mut ys := young(n, 0) // fresh spans: young
	setup_minors := vgc_minor_cycles_count() - m0
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
	println('dirty=${dirty}/${n} calls=${c1 - c0}/${c2 - c1} setup_minors=${setup_minors} minors=${vgc_minor_cycles_count() - m1} old_card=${old_card} bad=${bad} chain=${cnt}/${n} steps=${steps} last=${g.v} warm=${warm.len}')
}
