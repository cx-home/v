// vgc_recurring_plain_run_keeps_its_size_test.v — a pooled run of any
// recurring large size from the rounding's floor up (vgc_large_round_min,
// 256 pages), plain or frame, keeps its size through the pool's merges, so
// the next period's request of that size finds it by its exact size and
// takes it in place, whatever the order the period's requests arrive in
// (cx-home/v#58; vgc_pool_keeps_size in vlib/builtin/vgc_d_vgc.c.v, read by
// vgc_put_free_span's merge and vgc_pool_defrag). Before, only a frame's run
// (a quarter arena or more) kept its size: the batch writer's 1,156–1,920-
// page buffers, under the quarter and asked for every period, merged with
// their freed neighbours, and the next period's request of each size found
// no run of its length — the plain tails spent, it split the smallest kept
// frame run as the plain world's last resort, and the frames cascaded
// through the kept runs to a carve of the largest once a period
// (measure/collector-epic-78, G-1's split lines: 1,536, 1,920, 1,156, 1,408
// and 1,856 pages off the 2,432-page run, 19 times between cycles 125 and
// 297; the 6,144-page frame carved at cycles 238, 266 and 299).
//
// The shape (pages of 8 KB; the array's header adds one to each; three
// sizes under the quarter arena, each in its own granule block, so none is
// rounded): period 0 asks for 1200, 1500 and 1900 pages once, dropped and
// collected (their runs merge: the sizes are asked for once). Period 1 asks
// for the three in the same order — the sizes now recur — dropped and
// collected: on 7551309e2 the three runs merge into one, and period 2, asking
// in another order (1900, 1200, 1500), is served from that run's head or the
// arena's tail, nothing in place. Now each run keeps its size and period 2
// takes period 1's runs in place, and the arena count holds. Its own process
// (a fresh heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_recurring_plain_run_keeps_its_size_test.v
module main

const page = 8192 // vgc's page
const mask = usize(0x5a5a5a5a5a5a5a5a) // the runs' addresses kept off the stack's roots

@[noinline]
fn fill(n int) []u8 {
	mut b := []u8{len: n}
	for i := 0; i < n; i += 4096 {
		b[i] = u8(i)
	}
	return b
}

@[noinline]
fn drop_buf(n int) usize {
	b := fill(n)
	return usize(b.data) ^ mask
}

@[noinline]
fn scrub_stack() {
	mut pad := [65536]u8{}
	unsafe { C.memset(&pad[0], 0, 65536) }
	if pad[32768] != 0 {
		println('')
	}
}

// a period: the three buffers asked for in the given order, dropped at once;
// their addresses answered by size (1200, 1500, 1900 pages)
@[noinline]
fn period(order []int) (usize, usize, usize) {
	mut k12 := usize(0)
	mut k15 := usize(0)
	mut k19 := usize(0)
	for n in order {
		k := drop_buf(n * page)
		match n {
			1200 { k12 = k }
			1500 { k15 = k }
			else { k19 = k }
		}
	}
	return k12, k15, k19
}

fn test_a_recurring_plain_run_keeps_its_size_and_the_next_period_takes_it_in_place() {
	_, _, _ = period([1200, 1500, 1900]) // period 0: each size asked for once
	scrub_stack()
	gc_collect()
	gc_collect()
	k12, k15, k19 := period([1200, 1500, 1900]) // period 1: the sizes recur
	arenas1 := vgc_arenas_count()
	scrub_stack()
	gc_collect()
	gc_collect()
	p12, born12, pooled12 := vgc_span_probe(voidptr(k12 ^ mask))
	p15, born15, pooled15 := vgc_span_probe(voidptr(k15 ^ mask))
	p19, born19, pooled19 := vgc_span_probe(voidptr(k19 ^ mask))
	println('vgc_recurring_plain_run_keeps_its_size: after period 1 the 1200-page run reads ${p12} pages (born=${born12} pooled=${pooled12}), the 1500-page one ${p15} (born=${born15} pooled=${pooled15}), the 1900-page one ${p19} (born=${born19} pooled=${pooled19}), arenas ${arenas1}')
	assert pooled12 && born12 && p12 == 1201, 'the 1200-page buffer\'s run did not keep its size: ${p12} pages (pooled=${pooled12}), not 1201'
	assert pooled15 && born15 && p15 == 1501, 'the 1500-page buffer\'s run did not keep its size: ${p15} pages (pooled=${pooled15}), not 1501'
	assert pooled19 && born19 && p19 == 1901, 'the 1900-page buffer\'s run did not keep its size: ${p19} pages (pooled=${pooled19}), not 1901'
	k12c, k15c, k19c := period([1900, 1200, 1500]) // period 2, in another order
	arenas2 := vgc_arenas_count()
	println('vgc_recurring_plain_run_keeps_its_size: period 2 (1900, 1200, 1500) reads in place ${k19c == k19} ${k12c == k12} ${k15c == k15}, arenas ${arenas1} -> ${arenas2}')
	assert k19c == k19, 'the 1900-page buffer did not take its own run in place'
	assert k12c == k12, 'the 1200-page buffer did not take its own run in place'
	assert k15c == k15, 'the 1500-page buffer did not take its own run in place'
	assert arenas2 == arenas1, 'period 2 carved an arena: ${arenas1} -> ${arenas2}'
}
