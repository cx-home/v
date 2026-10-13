// vgc_span_stash_split_test.v — cx-home/v#40: a refill that finds no exact-fit
// span pooled splits a larger pooled run, and the batch's other pieces are split
// off under the same lock take into the thread's stash. Before, every such
// refill split one span and took free_spans_lock again: on FreeBSD CI at 4 jobs
// 3,226 of 5,571 lock takes in vgc_span_stash_test found no exact fit (the
// sweep's defrag had merged the pooled spans into runs), and the share of
// refills that took the lock read 60-73 % against the stash's < 60 %.
//
// Shape: one 16 MB buffer is dropped and collected, so the pool holds a large
// run; one thread then keeps ~96,000 small records alive (hundreds of 1-page
// span refills, each served from that run) and the share of its refills that
// took the lock is asserted under 60 % (a batch of 4 for 1-page spans: ~25 %;
// one take per refill: 100 %).
//
// Run: ./v test bench/parallel-alloc/vgc_span_stash_split_test.v
module main

@[heap]
struct Rec {
mut:
	a u64
	b u64
	c u64
	d u64
}

fn drop_big() {
	mut big := []u8{len: 16 * 1024 * 1024}
	big[0] = 1
	big[big.len - 1] = 2
}

fn test_refills_from_a_pooled_run_take_the_lock_once_per_batch() {
	$if vgc ? {
		drop_big()
		gc_collect()
		gc_collect()
		r0, t0 := vgc_pool_refill_stats()
		mut keep := []&Rec{cap: 96000}
		for i in 0 .. 96000 {
			keep << &Rec{
				a: u64(i)
			}
		}
		r1, t1 := vgc_pool_refill_stats()
		refills := r1 - r0
		takes := t1 - t0
		println('split refills: refills=${refills} lock_takes=${takes} share=${f64(takes) * 100.0 / f64(if refills > 0 {
			refills
		} else {
			u64(1)
		}):.1f}% kept=${keep.len}')
		assert refills >= 100, 'too few refills to judge: ${refills}'
		assert takes * 10 < refills * 6, 'the pool lock was taken on ${takes} of ${refills} refills from a pooled run'
	}
}
