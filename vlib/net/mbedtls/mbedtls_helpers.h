#ifndef V_NET_MBEDTLS_HELPERS_H
#define V_NET_MBEDTLS_HELPERS_H

static inline void v_mbedtls_ssl_set_bio_nonblocking(mbedtls_ssl_context *ssl, mbedtls_net_context *net)
{
	mbedtls_ssl_set_bio(ssl, net, mbedtls_net_send, mbedtls_net_recv, NULL);
}

// v_mbedtls_net_recv_timeout — mbedtls_net_recv_timeout for any descriptor:
// mbedtls' own waits with select(2) and refuses a descriptor >= FD_SETSIZE
// (1024) with MBEDTLS_ERR_NET_POLL_FAILED, so every TLS connection past about a
// thousand open descriptors failed its first read (cx-home/v#30). Below
// FD_SETSIZE it IS mbedtls' function; at and above, poll(2) in slices of at
// most 100 ms with a check that the descriptor is still open (as
// v_net_poll_one), then mbedtls_net_recv. Same contract: wait up to `timeout`
// ms (0 = no bound); a signal is MBEDTLS_ERR_SSL_WANT_READ, the bound elapsing
// MBEDTLS_ERR_SSL_TIMEOUT.
#if !defined(_WIN32)
#include <poll.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/select.h>
static int v_mbedtls_net_recv_timeout(void *ctx, unsigned char *buf, size_t len, uint32_t timeout)
{
	int fd = ((mbedtls_net_context *) ctx)->fd;
	if (fd < FD_SETSIZE) {
		return mbedtls_net_recv_timeout(ctx, buf, len, timeout);
	}
	long left = timeout == 0 ? -1 : (long) timeout;
	struct pollfd p;
	p.fd = fd;
	p.events = POLLIN;
	for (;;) {
		int slice = (left < 0 || left > 100) ? 100 : (int) left;
		p.revents = 0;
		int ret = poll(&p, 1, slice);
		if (ret > 0) {
			if (p.revents & POLLNVAL) {
				return MBEDTLS_ERR_NET_RECV_FAILED;
			}
			return mbedtls_net_recv(ctx, buf, len);
		}
		if (ret < 0) {
			if (errno == EINTR) {
				return MBEDTLS_ERR_SSL_WANT_READ;
			}
			return MBEDTLS_ERR_NET_RECV_FAILED;
		}
		if (fcntl(fd, F_GETFD) == -1) {
			return MBEDTLS_ERR_NET_RECV_FAILED;
		}
		if (left >= 0) {
			left -= slice;
			if (left <= 0) {
				return MBEDTLS_ERR_SSL_TIMEOUT;
			}
		}
	}
}
#else
static int v_mbedtls_net_recv_timeout(void *ctx, unsigned char *buf, size_t len, uint32_t timeout)
{
	return mbedtls_net_recv_timeout(ctx, buf, len, timeout);
}
#endif

#endif
