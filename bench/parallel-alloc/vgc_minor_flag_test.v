// cx-home/v#56 step 2: a cycle's kind (vgc_minor_this_cycle) is set by the thread whose phase
// CAS started the cycle, never by a call that loses the CAS. Beside a concurrent cycle's middle
// every allocating mutator reaches vgc_gc_start on its amortized trigger check (heap_live stays
// over next_gc until the cycle ends); a losing call that wrote its own plan into the flag turned
// a full concurrent cycle minor under VGC_YOUNG=1 — its end then skipped the full's records
// (vgc_full_marked / vgc_full_goal, the bound of the minors after it) and traced as a minor.
// Drives the white-box self-check in module builtin (vgc_minor_flag_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_minor_flag_test.v
module main

fn test_a_call_that_loses_the_phase_cas_leaves_the_running_cycle_kind() {
	rc := vgc_minor_flag_selftest()
	assert rc == 0, 'vgc_minor_flag_selftest check ${rc}'
}
