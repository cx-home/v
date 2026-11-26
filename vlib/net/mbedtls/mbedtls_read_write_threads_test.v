// vtest build: !(windows && tinyc)
// cx-home/cx-platform-store#90: a TLS store daemon under a steady writer died
// of 'double free or corruption (!prev)' or SIGSEGV; under ASan, a
// heap-use-after-free in mbedtls resize_buffer, the reader thread's
// mbedtls_ssl_read -> mbedtls_ssl_cx_release copying a record buffer the
// writer thread's mbedtls_ssl_write -> mbedtls_ssl_cx_release had freed. The
// store reads a connection on one thread and writes it on another; the cx
// fork's MBEDTLS_SSL_CX_RELEASE_BUFFERS made each call resize both record
// buffers. A read must touch only the input buffer, a write only the output
// buffer.
import net.mbedtls as _

#flag -lpthread
#insert "@VMODROOT/vlib/net/mbedtls/mbedtls_read_write_threads_test.h"

fn C.cx_rw_interleave(cert &char, key &char, out &int) int

fn C.cx_rw_threads(cert &char, key &char, rounds int, out &int) int

// a throwaway self-signed P-256 test certificate and its key
const rw_cert = '-----BEGIN CERTIFICATE-----\nMIIBgDCCASWgAwIBAgIUWHSX4lvDKS5f7+cTlnqYLY9JjlswCgYIKoZIzj0EAwIw\nFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAxNzEyMTUxOVoYDzIxMjYwOTIz\nMTIxNTE5WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO\nPQMBBwNCAASpkUzPGab9+dYVgR4jvey198t1DGRAPnXQnRhJFsrYuoERGgM/UPgi\neLw8YuVwl+5UWx71htpPGdnlA+f7P8vwo1MwUTAdBgNVHQ4EFgQUJF2bBdzntRr6\n81hxaMoLLeqWemMwHwYDVR0jBBgwFoAUJF2bBdzntRr681hxaMoLLeqWemMwDwYD\nVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAkyS4MSkwiPuukWvK6znM\nKzndk3M9a0B4s637NepZv5ACIQDUYap8I1OiKK2iAcTM2c6mdhbmUA6fGmW+Zb2i\nckOYNw==\n-----END CERTIFICATE-----\n'
const rw_key = '-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgKp/bQpevnUBXNSWA\nU5PPQ30cygFC06RDFBp5HOS0ZDuhRANCAASpkUzPGab9+dYVgR4jvey198t1DGRA\nPnXQnRhJFsrYuoERGgM/UPgieLw8YuVwl+5UWx71htpPGdnlA+f7P8vw\n-----END PRIVATE KEY-----\n'

fn test_a_read_leaves_the_output_buffer_and_a_write_the_input_buffer() {
	mut out := []int{len: 4}
	rc := C.cx_rw_interleave(&char(rw_cert.str), &char(rw_key.str), unsafe { &out[0] })
	assert rc == 0, 'the in-memory TLS 1.3 connection failed at step ${rc}'
	assert out[0] == 1, 'a read that ran while a write had grown the output buffer (${out[2]} bytes) resized or re-pointed it under the writer'
	assert out[1] == 1, 'a write that ran while a read had grown the input buffer (${out[3]} bytes) resized or re-pointed it under the reader'
}

fn test_one_reader_thread_and_one_writer_thread_on_one_connection() {
	mut out := []int{len: 3}
	rc := C.cx_rw_threads(&char(rw_cert.str), &char(rw_key.str), 3000, unsafe { &out[0] })
	assert rc == 0, 'the in-memory TLS 1.3 connection failed at step ${rc}'
	assert out[0] == 0, 'the server read thread failed: ${out[0]} (-1 = corrupted message)'
	assert out[1] == 0, 'the server write thread failed: ${out[1]}'
	assert out[2] == 0, 'the client failed: ${out[2]} (-1 = corrupted message)'
}
