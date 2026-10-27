// Several threads' allocation reaches the pacer within a sixteenth of the
// cycle's budget each (cx-home/v#56): a thread folds its private accounting
// into heap_live every (goal - marked) / 16 bytes, at least 64 KB, at most
// 1 MB. With the fixed 1 MB four csv workers held up to 4 MB the pacer had
// not seen against a 1 MB budget and carved ~300 spans past the goal.
// One allocating thread keeps the 1 MB flush (it hides at most one flush, and
// the scaled flush only added its collections: fasta 1M 527 -> 773).
// VGC_ACCT_FLUSH_DIV=0 restores the fixed 1 MB (this test then reads 4).
// Drives the white-box self-check in module builtin (vgc_acct_flush_selftest).
//
//   ../../v -gc e -cc cc test bench/parallel-alloc/vgc_acct_flush_test.v
//
// Requires -gc e (the vgc backend); the self-check is absent under -gc boehm/none.
module main

fn test_four_threads_hold_at_most_four_budget_sixteenths_unflushed_and_one_thread_keeps_1_mb() {
	rc := vgc_acct_flush_selftest()
	// 0 = ok; 1/2 = setup precondition; 3 = a collection in every round's
	// window; 4 = the workers held more unflushed bytes than the bound;
	// 5 = a cycle only one thread allocated in scaled the flush.
	assert rc == 0
}
