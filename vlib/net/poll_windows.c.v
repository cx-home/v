module net

import time

// poll_ready waits up to `timeout` until `handle` is ready for `what` (see
// poll_nix.c.v). Windows' fd_set is a list of sockets with no 1024 bound on
// the descriptor value, so select stays the mechanism there.
pub fn poll_ready(handle int, what PollFor, timeout time.Duration) !bool {
	test := match what {
		.read { Select.read }
		.write { Select.write }
		.except { Select.except }
	}

	return select_fdset(handle, test, timeout)
}
