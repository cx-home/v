// vtest build: macos && !tinyc
// cx-home/cx-platform-net#29 lever 10: 16 concurrent TLS 1.3 handshakes on darwin parked
// on mbedtls PSA's global key-slot mutex ~1,700 times per 2,000 handshakes (dev2,
// shim/lkcount.dylib), each park a kernel wait and two context switches, while the
// critical sections are a table lookup. A lock that finds the mutex held must
// mostly get it without parking: 16 threads cycling the ephemeral X25519 key
// (generate, export, agree, destroy) and its HKDF key schedule (import, MAC, destroy
// x12) park on fewer than 1 in 200 of their locks (dev2: 1 in 15-22 before the fix).
import net.mbedtls as _
import runtime

#insert "@VMODROOT/vlib/net/mbedtls/mbedtls_mutex_contention_test.h"

fn C.cx_mc_run(threads int, iters int, acq &f64, parks &f64, csw &f64) int

fn C.cx_mc_run2(threads int, iters int, acq &f64, parks &f64, csw &f64, vcsw &f64) int

fn C.getloadavg(loadavg &f64, nelem int) int

fn test_psa_key_cycle_under_16_threads_rarely_parks() {
	mut acq := 0.0
	mut parks := 0.0
	mut csw := 0.0
	failed := C.cx_mc_run(16, 400, &acq, &parks, &csw)
	println('16 threads x 400 key cycles: locks ${acq:.2f}/cycle, parks ${parks:.3f}/cycle, context switches ${csw:.3f}/cycle')
	assert failed == 0
	assert acq > 0, 'the lock counters of thirdparty/mbedtls/library/threading.c did not move'
	assert parks < acq / 200.0, 'parks ${parks:.3f} of ${acq:.2f} locks a cycle (bound 1 in 200)'
}

// cx-home/cx-platform-net#29 lever 11: after lever 10 the TLS 1.3 server on dev2 (16 reactors,
// 1,000-handshake wave) still parked ~1.1 times per handshake on the key-slot mutex (lkcount
// 1,113 / 1,000 hs), ~2 context switches each -- the whole herd sys gap to Python (1.232, bar
// 1.02). Lever 10's spin was a count (64 tries x 32 relaxes): ~100 us on x86 where pause costs
// ~140 cycles, ~1 us on arm64 where yield costs ~1 -- shorter than a 16-deep queue of
// key-slot holds, so arm64 parked (dev2 0.08-0.18 a cycle, dev1 0.016-0.028; x86 0.004).
// Bound: under 1 park per 100 handshakes' key work (16 threads, 400 cycles each), x3 rounds,
// the lowest round counts -- on a box where the 16 threads get cores of their own (20 cpus or
// more, load1 + 16 <= cpus at the start): a holder preempted by another runnable thread parks
// its waiters whatever the spin (dev1, 12 cpus inside a 6-job suite: 0.021-0.046 with the fix),
// so elsewhere the run is checked, not the bound.
fn test_psa_key_cycle_under_16_threads_parks_under_1_per_100_handshakes() {
	cpus := runtime.nr_cpus()
	mut la := [3]f64{}
	C.getloadavg(&la[0], 3)
	mut best := 1.0e9
	for round in 0 .. 3 {
		mut acq := 0.0
		mut parks := 0.0
		mut csw := 0.0
		mut vcsw := 0.0
		failed := C.cx_mc_run2(16, 400, &acq, &parks, &csw, &vcsw)
		println('round ${round}: 16 threads x 400 key cycles: locks ${acq:.2f}/cycle, parks ${parks:.4f}/cycle, context switches ${csw:.3f}/cycle (voluntary ${vcsw:.3f})')
		assert failed == 0
		assert acq > 0, 'the lock counters of thirdparty/mbedtls/library/threading.c did not move'
		if parks < best {
			best = parks
		}
	}
	if cpus < 20 || la[0] + 16.0 > f64(cpus) {
		println('${cpus} cpus, load1 ${la[0]:.1f}: 16 threads do not get cores of their own -- the run is checked, not the bound')
		return
	}
	assert best < 0.01, 'parks ${best:.4f} a handshake cycle at 16 threads (bound 0.01; ${cpus} cpus, load1 ${la[0]:.1f})'
}
