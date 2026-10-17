// vtest build: !(windows && tinyc)
// cx-home/v#39: a TLS connection whose handshake is waiting on its peer keeps
// idle-size record buffers. A one-worker TLS server facing a reconnect wave
// from a slower client held a thousand connections mid-handshake at once, each
// with two full ~16.7 KB record buffers: its peak RSS read 1.41x Go's. The
// buffers now start at the idle size, the input one grows only for a record
// that does not fit, and both shrink whenever a handshake returns WANT_READ
// with its flight sent (mbedtls_ssl_cx_release_wait).
import net.mbedtls as _

#insert "@VMODROOT/vlib/net/mbedtls/mbedtls_handshake_wait_buffers_test.h"

fn C.cx_hw_run(cert &char, key &char, out &int) int

const wait_bound = 4096
// a throwaway self-signed P-256 test certificate and its key
const hw_cert = '-----BEGIN CERTIFICATE-----\nMIIBgDCCASWgAwIBAgIUWHSX4lvDKS5f7+cTlnqYLY9JjlswCgYIKoZIzj0EAwIw\nFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAxNzEyMTUxOVoYDzIxMjYwOTIz\nMTIxNTE5WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO\nPQMBBwNCAASpkUzPGab9+dYVgR4jvey198t1DGRAPnXQnRhJFsrYuoERGgM/UPgi\neLw8YuVwl+5UWx71htpPGdnlA+f7P8vwo1MwUTAdBgNVHQ4EFgQUJF2bBdzntRr6\n81hxaMoLLeqWemMwHwYDVR0jBBgwFoAUJF2bBdzntRr681hxaMoLLeqWemMwDwYD\nVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAkyS4MSkwiPuukWvK6znM\nKzndk3M9a0B4s637NepZv5ACIQDUYap8I1OiKK2iAcTM2c6mdhbmUA6fGmW+Zb2i\nckOYNw==\n-----END CERTIFICATE-----\n'
const hw_key = '-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgKp/bQpevnUBXNSWA\nU5PPQ30cygFC06RDFBp5HOS0ZDuhRANCAASpkUzPGab9+dYVgR4jvey198t1DGRA\nPnXQnRhJFsrYuoERGgM/UPgieLw8YuVwl+5UWx71htpPGdnlA+f7P8vw\n-----END PRIVATE KEY-----\n'

fn test_a_handshake_waiting_on_its_peer_holds_idle_record_buffers() {
	mut out := []int{len: 5}
	rc := C.cx_hw_run(&char(hw_cert.str), &char(hw_key.str), unsafe { &out[0] })
	assert rc == 0, 'the in-memory TLS 1.3 handshake failed at step ${rc}'
	eprintln('record buffer bytes: server after setup ${out[0]}, client waiting after its ClientHello ${out[1]}, server waiting after its flight ${out[2]}, server after the handshake ${out[3]}; transfers intact ${out[4]}')
	assert out[0] <= wait_bound, 'an accepted server connection holds ${out[0]} bytes of record buffers before its ClientHello (bound ${wait_bound})'
	assert out[1] <= wait_bound, 'a client waiting for the server flight holds ${out[1]} bytes of record buffers (bound ${wait_bound})'
	assert out[2] <= wait_bound, 'a server waiting for the client Finished holds ${out[2]} bytes of record buffers (bound ${wait_bound})'
	assert out[3] <= wait_bound, 'a server connection after its handshake holds ${out[3]} bytes of record buffers (bound ${wait_bound})'
	assert out[4] == 1, 'a 20,000-byte transfer each way did not cross intact after the buffers shrank'
}
