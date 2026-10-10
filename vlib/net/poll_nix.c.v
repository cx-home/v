module net

import time

#include "@VMODROOT/vlib/net/v_poll_one.h"

fn C.v_net_poll_one(fd i32, what i32, timeout_ms i32) i32

// poll_timeout_ms converts a wait bound for poll(2): infinite (or negative)
// is -1, a positive bound under a millisecond rounds UP to 1 ms (never a
// busy 0), and a bound past i32 milliseconds clamps.
fn poll_timeout_ms(timeout time.Duration) i32 {
	if timeout == infinite_timeout || timeout < 0 {
		return -1
	}
	if timeout == 0 {
		return 0
	}
	ms := (i64(timeout) + i64(time.millisecond) - 1) / i64(time.millisecond)
	if ms > i64(max_i32) {
		return max_i32
	}
	return i32(ms)
}

// poll_ready waits up to `timeout` (infinite_timeout: no bound) until `handle`
// is ready for `what`: true when ready, false on timeout, an error (code =
// errno) when the wait fails. Below FD_SETSIZE it is select(2), as every wait
// in this module always was; at 1024 and up — where select fails (macOS) or
// overflows its fd_set (glibc), which a server holding a thousand connections
// reaches — it is poll(2) (v_poll_one.h, cx-home/v#30).
pub fn poll_ready(handle int, what PollFor, timeout time.Duration) !bool {
	if handle < C.FD_SETSIZE {
		test := match what {
			.read { Select.read }
			.write { Select.write }
			.except { Select.except }
		}

		return select_fdset(handle, test, timeout)
	}
	w := match what {
		.read { 0 }
		.write { 1 }
		.except { 2 }
	}

	res := C.v_net_poll_one(handle, w, poll_timeout_ms(timeout))
	if res < 0 {
		code := error_code()
		return error_with_code('net: socket error: ${code}', code)
	}
	return res > 0
}
