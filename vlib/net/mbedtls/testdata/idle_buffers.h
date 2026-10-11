// idle_buffers.h — mbedtls_idle_buffers_release_test.v reads how many bytes a
// connection's two TLS record buffers hold (cx-platform-xap#20). Without
// MBEDTLS_SSL_VARIABLE_BUFFER_LENGTH the buffers are fixed at their full size (at least the content lengths).
#include <mbedtls/ssl.h>
static inline int cx_test_ssl_buffer_bytes(mbedtls_ssl_context *s) {
#if defined(MBEDTLS_SSL_VARIABLE_BUFFER_LENGTH)
	return (int) (s->private_in_buf_len + s->private_out_buf_len);
#else
	(void) s;
	return (int) (MBEDTLS_SSL_IN_CONTENT_LEN + MBEDTLS_SSL_OUT_CONTENT_LEN);
#endif
}

// cx_test_ssl_holds_handshake — 1 while the connection still holds its
// handshake parameters (a TLS 1.3 server no longer needs them once the
// handshake is over).
static inline int cx_test_ssl_holds_handshake(mbedtls_ssl_context *s) {
	return s->private_handshake != NULL;
}
