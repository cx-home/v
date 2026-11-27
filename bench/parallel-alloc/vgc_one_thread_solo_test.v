// vgc_one_thread_solo_test.v — RULING (OPERATOR) 94-CARVE (b), 07:45 ET 11-27
// (https://github.com/cx-home/v/issues/94): the bounded carve allowance of an
// expensive one-thread program holds where ONE thread allocates but the pacing
// reads several.
//
// cx's put-docs runs its interpreter thread alone between stops (nt=1 at ~95 %
// of them), but its parquet workers burst once every few stops and the pacing
// keeps 'several' for the stops after a burst (vgc_pace_prev_window,
// vgc_pace_exit): one=1 at 6-30 of ~100 stops. Under several the adaptive floor
// is clamp(2 x marked, 4 MB, 32 MB) whatever the collections cost, so the
// allowance (vgc_one_lift_pct) never applied: dev2 timed x5, 1.12-1.15 s user
// against VGC_HEADROOM_ADAPTIVE_FLOOR=0's 1.04-1.08 (attrs) — the bar's half 2.
// A churn child does not show the shape (its transients die in the minor
// collections, and a helper's large bursts are not a second allocating thread),
// so the decision and the bound are read white-box (vgc_one_solo_selftest,
// module builtin): one by the pacing stays one; several by the pacing with at
// most one allocating thread is one for the lift; two or more threads are
// several; VGC_ONE_LIFT_SOLO=0 is the decision alone; the bound is
// clamp(vgc_one_lift_pct x marked, 4 MB, 32 MB).
//
// Run: ./v test bench/parallel-alloc/vgc_one_thread_solo_test.v
module main

fn test_one_allocating_thread_paced_several_is_one_for_the_carve_allowance() {
	rc := vgc_one_solo_selftest()
	assert rc == 0, 'vgc_one_solo_selftest check ${rc}'
}
