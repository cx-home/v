// vtest build: macos && !tinyc
// cx-home/cx-platform-net#29 lever 10: 16 concurrent TLS 1.3 handshakes on darwin parked
// on mbedtls PSA's global key-slot mutex ~1,700 times per 2,000 handshakes (dev2,
// shim/lkcount.dylib), each park a kernel wait and two context switches, while the
// critical sections are a table lookup. A lock that finds the mutex held must
// mostly get it without parking: 16 threads cycling the ephemeral X25519 key
// (generate, export, agree, destroy) and its HKDF key schedule (import, MAC, destroy
// x12) park on fewer than 1 in 200 of their locks (dev2: 1 in 15-22 before the fix).
import net.mbedtls as _

#insert "@VMODROOT/vlib/net/mbedtls/mbedtls_mutex_contention_test.h"

fn C.cx_mc_run(threads int, iters int, acq &f64, parks &f64, csw &f64) int

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
