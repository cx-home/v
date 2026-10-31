// vgc_wb_epoch_test.v — cx-home/v#56 lever 3: the stop count the generated
// C's second write-barrier gate compares against (vgc_wb_epoch) moves at
// every stop, and only at a stop.
fn test_every_stop_moves_the_count() {
	e0 := vgc_wb_epoch
	gc_collect()
	e1 := vgc_wb_epoch
	assert e1 > e0
	gc_collect()
	assert vgc_wb_epoch > e1
}

fn test_the_count_stands_between_stops() {
	gc_collect()
	e := vgc_wb_epoch
	mut s := u64(0)
	for i in 0 .. 100000 {
		s += u64(i)
	}
	assert s == 4999950000
	assert vgc_wb_epoch == e
}
