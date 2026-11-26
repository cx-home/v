// vtest build: !(windows && tinyc)
// A TLS 1.3 server frees its handshake parameters when its handshake ends
// (the cx fork's mbedtls_ssl_cx_release), but mbedtls_ssl_free frees the
// connection's transform_negotiate (456 bytes on Linux arm64) only while
// ssl->handshake is still set: every accepted TLS connection leaked it
// (LeakSanitizer, gcc 16 Linux arm64, found by the
// https://github.com/cx-home/cx-platform-store/issues/90 harness).
import net.mbedtls as _

#flag -lpthread
#insert "@VMODROOT/vlib/net/mbedtls/mbedtls_read_write_threads_test.h"

fn C.cx_rw_released(cert &char, key &char, out &int) int

const rw_cert = '-----BEGIN CERTIFICATE-----\nMIIBgDCCASWgAwIBAgIUWHSX4lvDKS5f7+cTlnqYLY9JjlswCgYIKoZIzj0EAwIw\nFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAxNzEyMTUxOVoYDzIxMjYwOTIz\nMTIxNTE5WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO\nPQMBBwNCAASpkUzPGab9+dYVgR4jvey198t1DGRAPnXQnRhJFsrYuoERGgM/UPgi\neLw8YuVwl+5UWx71htpPGdnlA+f7P8vwo1MwUTAdBgNVHQ4EFgQUJF2bBdzntRr6\n81hxaMoLLeqWemMwHwYDVR0jBBgwFoAUJF2bBdzntRr681hxaMoLLeqWemMwDwYD\nVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAkyS4MSkwiPuukWvK6znM\nKzndk3M9a0B4s637NepZv5ACIQDUYap8I1OiKK2iAcTM2c6mdhbmUA6fGmW+Zb2i\nckOYNw==\n-----END CERTIFICATE-----\n'
const rw_key = '-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgKp/bQpevnUBXNSWA\nU5PPQ30cygFC06RDFBp5HOS0ZDuhRANCAASpkUzPGab9+dYVgR4jvey198t1DGRA\nPnXQnRhJFsrYuoERGgM/UPgieLw8YuVwl+5UWx71htpPGdnlA+f7P8vw\n-----END PRIVATE KEY-----\n'

fn test_a_tls13_server_that_released_its_handshake_holds_no_negotiation_state() {
	mut out := []int{len: 3}
	rc := C.cx_rw_released(&char(rw_cert.str), &char(rw_key.str), unsafe { &out[0] })
	assert rc == 0, 'the in-memory TLS 1.3 connection failed at step ${rc}'
	assert out[0] == 1, 'the server kept its handshake parameters after the handshake'
	assert out[1] == 1, 'the server released its handshake but kept transform_negotiate, which mbedtls_ssl_free no longer frees'
	assert out[2] == 1, 'the server released its handshake but kept session_negotiate, which mbedtls_ssl_free no longer frees'
}
