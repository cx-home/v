// https://github.com/cx-home/v/issues/94: entering several allocating threads reads a stop within the
// last vgc_pace_enter_window stops (16) that counted two or more threads over 64 KB as 'the stop
// before' (vgc_pace_prev_window), not only the stop right before. cx's put-docs runs its interpreter
// thread alone between stops and its parquet workers in bursts one stop reads (acct=4 live=5 once
// every ~7 stops); entering took two such stops running, which the quarter's short intervals never
// give, and leaving several takes 8 quiet stops, which GOGC=100's long intervals never give, so a run
// stayed in whichever pacing it fell into (one=1 in 7-45 of 110-133 cycles some runs, 130-209 of
// 143-219 others, one binary) and the kit that allocates less read more collections than its parent.
// A one-off burst (json-codec k=1's hand-over) still reads one.
// Drives the white-box self-check in module builtin (vgc_pace_window_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pace_window_test.v
module main

fn test_a_recurring_burst_enters_several() {
	rc := vgc_pace_window_selftest()
	assert rc == 0, 'vgc_pace_window_selftest check ${rc}'
}
