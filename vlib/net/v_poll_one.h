#ifndef V_NET_POLL_ONE_H
#define V_NET_POLL_ONE_H
// v_net_poll_one waits for ONE descriptor with poll(2) — for descriptors at or
// above FD_SETSIZE (1024), which select(2) cannot take (macOS fails it with
// EINVAL; FD_SET writes past the fd_set on glibc). `what` is 0 = read,
// 1 = write, 2 = except (priority data); `timeout_ms` < 0 waits without bound.
// Returns > 0 when ready (an error or hang-up on the descriptor counts as
// ready, as select reports it), 0 on timeout, -1 with errno set on failure.
//
// The wait runs in slices of at most 100 ms and checks that the descriptor is
// still open between them: a thread blocked in select on macOS wakes when
// another thread closes the descriptor (a listener's accept loop stops that
// way), and poll does not — so a close ends this wait with EBADF within one
// slice instead of never.
#include <poll.h>
#include <errno.h>
#include <fcntl.h>
static inline int v_net_poll_one(int fd, int what, int timeout_ms) {
	struct pollfd p;
	p.fd = fd;
	p.events = what == 0 ? POLLIN : (what == 1 ? POLLOUT : POLLPRI);
	for (;;) {
		int slice = (timeout_ms < 0 || timeout_ms > 100) ? 100 : timeout_ms;
		p.revents = 0;
		int r = poll(&p, 1, slice);
		if (r != 0) {
			if (r > 0 && (p.revents & POLLNVAL)) {
				errno = EBADF;
				return -1;
			}
			return r;
		}
		if (fcntl(fd, F_GETFD) == -1) {
			errno = EBADF;
			return -1;
		}
		if (timeout_ms >= 0) {
			timeout_ms -= slice;
			if (timeout_ms <= 0) {
				return 0;
			}
		}
	}
}
#endif
