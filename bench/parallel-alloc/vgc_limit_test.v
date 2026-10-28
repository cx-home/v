// The collector's CPU limit past the soft limit (cx-examples#403): while the live set
// holds the pacer goal at its minimum budget over the soft limit, a cycle whose
// collector time reached the mutators' wall time since the previous cycle doubles the
// next budget (marked/16 << shift, shift at most 4: the live set), a cycle under 1/8
// of it halves it back, and a goal under the limit resets it — Go's GC CPU limiter
// shape. Twelve 475 MB xlsx parses in one process ran 20 cycles of 2-4 GB marks at
// marked/16 (42 s of CPU for 18 s of work).
// Drives the white-box self-check in module builtin (vgc_limit_selftest).
//
//   ../../v -gc e -cc cc test bench/parallel-alloc/vgc_limit_test.v
//
// Requires -gc e (the vgc backend); the self-check is absent under -gc boehm/none.
module main

fn test_the_budget_past_the_soft_limit_doubles_while_the_collector_costs_the_mutators_time() {
	assert vgc_limit_selftest() == 0
}
