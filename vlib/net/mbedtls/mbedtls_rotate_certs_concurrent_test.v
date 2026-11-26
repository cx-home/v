// vtest build: !(windows && tinyc) // TODO: fix these by adding declarations for the missing functions in the prebuilt tcc
module main

import net.mbedtls
import sync
import time

// mbedtls_rotate_certs_concurrent_test.v — SSLListener.rotate_certs while
// handshakes are live on the same listener (cx-home/cx-platform-store
// heap corruption after a TLS reload; kind-split lead 3).
//
// rotate_certs parses the new key with the listener's ctr_drbg
// (mbedtls_pk_parse_key: an EC key without its public point derives it with
// a blinded multiplication that draws the rng) while accepted connections'
// handshakes draw the same ctr_drbg through tls_listener_rng. Superseded
// identity generations must stay alive while connections set up against them
// are still handshaking or talking. The test runs both at once — two rotators
// alternating an EC identity (no public point: the rng path) and an RSA one,
// an accept thread handing each connection to its own handshake thread, and
// several clients connecting in a loop — and then checks that a NEW handshake
// presents the identity installed last. Build it with
// -cflags -fsanitize=address (or thread) to read the memory side; without a
// sanitizer it still fails on a crash, a failed rotation or a handshake error.

const rot_ec_cert = '-----BEGIN CERTIFICATE-----\nMIIBfjCCASWgAwIBAgIUMduxByzvbHSrYv6OUVm5N/SLV84wCgYIKoZIzj0EAwIw\nFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTEyNjE0MzA1OVoYDzIxMjYxMTAy\nMTQzMDU5WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggqhkjO\nPQMBBwNCAAQ2AzBSnEmqK/uitL4Xm1wkrGNTI6b7NSwCKLWDsR/ard1fTps2msb7\nrY6m+xq1u5JR33McD+GDT5vDLpzwKRuXo1MwUTAdBgNVHQ4EFgQUftod0QgNwgfR\nyVXOSOweyHMVa7MwHwYDVR0jBBgwFoAUftod0QgNwgfRyVXOSOweyHMVa7MwDwYD\nVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNHADBEAiB2BcHN5H2dmLNmWGoxFlpK\npA+vkvhSP9b+RPVIiiPIQwIgASsajQhR9m7Glo4IBDEQQbk3/lcSvUovX1w6e9ls\nA78=\n-----END CERTIFICATE-----\n'
const rot_ec_key = '-----BEGIN EC PRIVATE KEY-----\nMDECAQEEIEsMa/V1Xh83JuPblZk/W/acpA4zywCnbX1waa0YSWU5oAoGCCqGSM49\nAwEH\n-----END EC PRIVATE KEY-----\n'
const rot_rsa_cert = '-----BEGIN CERTIFICATE-----\nMIIEOTCCAyECFG64Q2g46jZb3kRbDOJWX/BwjSp6MA0GCSqGSIb3DQEBCwUAMEUx\nCzAJBgNVBAYTAkFVMRMwEQYDVQQIDApTb21lLVN0YXRlMSEwHwYDVQQKDBhJbnRl\ncm5ldCBXaWRnaXRzIFB0eSBMdGQwIBcNMjMwODAyMTcyOTQyWhgPMjA1MDEyMTcx\nNzI5NDJaMGsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRQwEgYD\nVQQHDAtMb3MgQW5nZWxlczEdMBsGA1UECgwUQ2F0YWx5c3QgRGV2ZWxvcG1lbnQx\nEjAQBgNVBAMMCWxvY2FsaG9zdDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC\nggIBALqAI4fqUi+QBVWcsXglouLdOML5+w0+1hSR1KdO0Q5XPdQAs/yYWJ+KUkDw\nG++rfy9DUPq7FNRBVurXQkcAtn6gXdllGUSjwUiDo/N4mMOyS/2sufBuaeww7jVi\nrppH+zwP1tUnjRd6khl6bi1Ian9VSzr3Iy9CkXIg1GU4CPXkOydLeoQfepXxWoK1\nOUNwT3VKC/stAfY3j/NIIeiJYkyuRGFCkxn/BUjN+AsXiTugRcYKEFHdIPkOuCXp\nYbhf+lLsczpxCs3rdZG9b/N6mEDCzXTmeHkmsjdPTf+1k5DZZvKzVBBrgdxCgBb7\n5RwjF5v9WmnIc33wWgfJC6FaUzj9NYxYUbPHD+jTz0rJB/jj4u/xJlM/e5NRmXdW\n70pOMKXtWjRSolLOFIPKLY1qs3KMTAZxKKWPDDF7WlMJxMRt7nnnks5yw43Nog4C\njDLk1ZgETnPpLgo3jbmJdIv+OHKTJrBlVvDq7VTyixCoS5G8KoOmyQJhaXG6NwE2\niVhH5JIKgzgCfetfDsnjxqJ/qtrFXPa8FF2TsomD0NK/GZmIcs+9OeVB75Jn5uhF\nfLHScpiTbuu5w3P/LI/MqihLRB6RRNnRzPH8fIg5bYC9b770ta/8GcFRuYE8t+UR\nGtqXJoIKixbDlqV54kal8FQzYzhETf9+NM6Kb/lKEfG/pslvAgMBAAEwDQYJKoZI\nhvcNAQELBQADggEBALI3uNiNO0QE1brA3QYFK+d9ZroB72NrJ0UNkzYHDg2Fc6xg\n4aVVfaxY08+TmKc0JlMOW+pUxeCW/+UBSngdQiR9EE9xm0k0XIrAsy9RXxRvEtPu\nM1VI2h7ayp1Y2BrnQinevTSgtqLRyS1VbOFRl1FiyVvinw2I0KsDdAMNevAPXcOa\nQ8pUgUq6f56DkhocQaj+hxD/uV8HryNxuoSXnPhvfTN3z4YRGzsaWevJ9EYJliOM\n+XugcqfFJ+W7/QCEcAHCL+Bw6OydG5NFORr3p57PXjjcL/uKmxPBrWg2Bz6uT4uR\nMhj0zttiFHLAt9jGfyk6W57UNUja1e1ggftJJhs=\n-----END CERTIFICATE-----\n'
const rot_rsa_key = '-----BEGIN RSA PRIVATE KEY-----\n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\n-----END RSA PRIVATE KEY-----\n'

const rot_clients = 8
const rot_min_rotations = 150 // per rotator
const rot_min_handshakes = 300 // rotations continue until this many completed

struct RotStats {
mut:
	mu         &sync.Mutex = sync.new_mutex()
	handshakes int
	client_ok  int
	errors     []string
}

fn (mut s RotStats) add_err(msg string) {
	s.mu.lock()
	if s.errors.len < 20 {
		s.errors << msg
	}
	s.mu.unlock()
}

fn rot_serve_one(mut conn mbedtls.SSLConn, mut st RotStats) {
	defer {
		conn.shutdown() or {}
	}
	conn.complete_handshake(10 * time.second) or {
		// a client that gave up mid-handshake is not a server fault
		return
	}
	st.mu.lock()
	st.handshakes++
	st.mu.unlock()
	conn.write_string('ok') or {}
}

fn rot_accept_loop(mut l mbedtls.SSLListener, stop &sync.WaitGroup, mut st RotStats, done &bool) {
	mut workers := []thread{}
	for !*done {
		mut conn := l.accept_raw_with_timeout(100 * time.millisecond) or { continue }
		workers << spawn rot_serve_one(mut conn, mut st)
	}
	workers.wait()
	mut wg := unsafe { stop }
	wg.done()
}

fn rot_client(port int, mut st RotStats, done &bool) {
	for !*done {
		mut c := mbedtls.new_ssl_conn(validate: false) or {
			st.add_err('new_ssl_conn: ${err}')
			return
		}
		c.dial('127.0.0.1', port) or {
			st.add_err('dial: ${err}')
			continue
		}
		mut buf := []u8{len: 8}
		n := c.read(mut buf) or { 0 }
		if n == 2 && buf[..2].bytestr() == 'ok' {
			st.mu.lock()
			st.client_ok++
			st.mu.unlock()
		}
		c.shutdown() or {}
	}
}

fn rot_rotator(mut l mbedtls.SSLListener, start_ec bool, mut st RotStats, rotations &int) {
	deadline := time.now().add(90 * time.second)
	for i := 0; true; i++ {
		st.mu.lock()
		h := st.handshakes
		st.mu.unlock()
		if i >= rot_min_rotations && (h >= rot_min_handshakes || time.now() > deadline) {
			break
		}
		ec := (i % 2 == 0) == start_ec
		cfg := if ec {
			mbedtls.SSLConnectConfig{
				cert:                   rot_ec_cert
				cert_key:               rot_ec_key
				in_memory_verification: true
			}
		} else {
			mbedtls.SSLConnectConfig{
				cert:                   rot_rsa_cert
				cert_key:               rot_rsa_key
				in_memory_verification: true
			}
		}
		l.rotate_certs(cfg) or { st.add_err('rotate ${i}: ${err}') }
		st.mu.lock()
		unsafe {
			mut r := rotations
			*r = *r + 1
		}
		st.mu.unlock()
	}
}

fn test_rotate_certs_under_concurrent_handshakes() {
	spawn fn () {
		time.sleep(240 * time.second)
		eprintln('mbedtls rotate_certs test: timeout reached, exiting.')
		exit(1)
	}()
	mut l := mbedtls.new_ssl_listener('127.0.0.1:0', mbedtls.SSLConnectConfig{
		cert:                   rot_rsa_cert
		cert_key:               rot_rsa_key
		in_memory_verification: true
	})!
	port := l.addr()!.port()!
	mut st := &RotStats{}
	mut done := false
	mut stop := sync.new_waitgroup()
	stop.add(1)
	spawn rot_accept_loop(mut l, stop, mut st, &done)
	mut clients := []thread{}
	for _ in 0 .. rot_clients {
		clients << spawn rot_client(port, mut st, &done)
	}
	// let handshakes get going before the first rotation
	for _ in 0 .. 200 {
		st.mu.lock()
		h := st.handshakes
		st.mu.unlock()
		if h >= rot_clients {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	mut rotations := 0
	r1 := spawn rot_rotator(mut l, true, mut st, &rotations)
	r2 := spawn rot_rotator(mut l, false, mut st, &rotations)
	r1.wait()
	r2.wait()
	// the last identity installed: EC — a validating client trusting only the
	// EC self-signed certificate must complete a NEW handshake.
	l.rotate_certs(cert: rot_ec_cert, cert_key: rot_ec_key, in_memory_verification: true)!
	mut v := mbedtls.new_ssl_conn(validate: true, verify: rot_ec_cert, in_memory_verification: true)!
	v.dial('localhost', port)!
	mut vb := []u8{len: 8}
	vn := v.read(mut vb)!
	assert vb[..vn].bytestr() == 'ok'
	v.shutdown() or {}

	done = true
	clients.wait()
	stop.wait()
	l.shutdown()!
	eprintln('rotate_certs: ${rotations + 1} rotations, server handshakes ${st.handshakes}, client reads ok ${st.client_ok}')
	assert st.errors.len == 0, st.errors.str()
	assert st.handshakes >= rot_min_handshakes
	assert st.client_ok >= rot_min_handshakes - rot_clients
}
