// cx-private#1923 §2: a schedule-perturbation mode. Random yields at the
// allocator's safepoint poll and at every caller's perturbation point (cx's
// channel locks) produce, on purpose, the interleavings a quiet box never does,
// so the stress corpus can run under them. VGC_PERTURB=<per-mille> (0..1000)
// turns it on at start-up, VGC_PERTURB_SEED=<n> seeds it; off, a point is one
// load and a branch.
//
//   ../../v -gc e test bench/parallel-alloc/vgc_perturb_test.v
module main

fn test_off_by_default_a_point_takes_nothing() {
	vgc_perturb_set(0, 1)
	before := vgc_perturb_taken()
	for _ in 0 .. 10000 {
		vgc_perturb()
	}
	assert vgc_perturb_taken() == before
}

fn test_every_point_yields_at_one_thousand_per_mille() {
	vgc_perturb_set(1000, 1)
	before := vgc_perturb_taken()
	for _ in 0 .. 1000 {
		vgc_perturb()
	}
	taken := vgc_perturb_taken() - before
	vgc_perturb_set(0, 1)
	assert taken == 1000
}

fn test_the_rate_is_the_per_mille_asked() {
	vgc_perturb_set(100, 7)
	before := vgc_perturb_taken()
	for _ in 0 .. 100000 {
		vgc_perturb()
	}
	taken := vgc_perturb_taken() - before
	vgc_perturb_set(0, 1)
	assert taken > 8000 && taken < 12000, 'taken ${taken} of 100000 at 100 per mille'
}

// the allocator's safepoint poll is a perturbation point: refills that cross it yield
fn test_the_allocators_poll_perturbs() {
	vgc_perturb_set(1000, 3)
	before := vgc_perturb_taken()
	mut keep := []&int{cap: 4}
	for i in 0 .. 200000 {
		p := &int(unsafe { malloc(48) })
		unsafe {
			*p = i
		}
		if i % 50000 == 0 {
			keep << p
		}
	}
	taken := vgc_perturb_taken() - before
	vgc_perturb_set(0, 1)
	assert keep.len == 4
	assert taken > 0, 'no yield at the allocator poll over 200000 allocations'
}

// VGC_PERTURB's value: a per-mille, clamped to 1000; anything else is off
fn test_the_environment_value_reads_as_a_per_mille() {
	assert vgc_perturb_parse(c'250') == 250
	assert vgc_perturb_parse(c'5000') == 1000
	assert vgc_perturb_parse(c'0') == 0
	assert vgc_perturb_parse(c'-3') == 0
	assert vgc_perturb_parse(c'x') == 0
	assert vgc_perturb_parse(unsafe { nil }) == 0
}

// threads draw from their own sequences: four threads at 500 per mille all yield
fn test_threads_perturb_independently() {
	vgc_perturb_set(500, 11)
	before := vgc_perturb_taken()
	mut ts := []thread{}
	for _ in 0 .. 4 {
		ts << spawn fn () {
			for _ in 0 .. 20000 {
				vgc_perturb()
			}
		}()
	}
	ts.wait()
	taken := vgc_perturb_taken() - before
	vgc_perturb_set(0, 1)
	assert taken > 32000 && taken < 48000, 'taken ${taken} of 80000 at 500 per mille'
}
