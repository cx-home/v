// vtest build: !(windows && tinyc) // TODO: fix these by adding declarations for the missing functions in the prebuilt tcc
module mbedtls

import time

fn C.mbedtls_ssl_get_peer_cert(ssl &C.mbedtls_ssl_context) voidptr
fn C.mbedtls_ssl_get_verify_result(ssl &C.mbedtls_ssl_context) u32

// mbedtls_optional_client_cert_test.v — cx-home/v#78. A server that sends a
// CertificateRequest but does not require a certificate (kube-apiserver does:
// its client certificate is optional) must still complete the handshake with
// a client that pins the server's CA (`verify`) and has no certificate of its
// own. SSLConn.init configured an own certificate whenever verify, cert or
// cert_key was set, so with only `verify` mbedtls held an EMPTY cert/key pair
// as the client's identity and, asked for a certificate, failed the handshake
// (-28160, MBEDTLS_ERR_SSL_HANDSHAKE_FAILURE) instead of answering with an
// empty Certificate message. The server here is a net.mbedtls listener whose
// authmode is set to OPTIONAL (it sends a CertificateRequest naming the test
// CA). The second test keeps mutual TLS honest: a client with cert + key is
// still asked, still answers, and the server verifies its certificate.
// Certificates: P-256, CA "cx test v78 ca", server CN/SAN localhost and
// 127.0.0.1, client CN "cx test v78 client"; valid for 100 years.
const v78_ca = '-----BEGIN CERTIFICATE-----\nMIIBiTCCAS+gAwIBAgIUBSci9Ez7xqXOJXwKaXAb1f+aop8wCgYIKoZIzj0EAwIw\nGTEXMBUGA1UEAwwOY3ggdGVzdCB2NzggY2EwIBcNMjYxMTIwMDgxMjQ3WhgPMjEy\nNjEwMjcwODEyNDdaMBkxFzAVBgNVBAMMDmN4IHRlc3Qgdjc4IGNhMFkwEwYHKoZI\nzj0CAQYIKoZIzj0DAQcDQgAEGS1Lhj10sMW7AulIElEyd/zQr0FCD8qymaNgEPpY\nEuLgwijkv1n+cCLc3AThdWYCQFIZWXGec56wqX9yJAQMZ6NTMFEwHQYDVR0OBBYE\nFDGtMpBS6bs6R7dNQbYLXB2vN+DSMB8GA1UdIwQYMBaAFDGtMpBS6bs6R7dNQbYL\nXB2vN+DSMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAKFhnyGB\nojZA/s5pyM8UenXatTmP3/DH0UAUltcW1yWnAiAywJk8uns7J8KZcRzcazoo4Gzu\n0uYu5GaSIdji6JYCow==\n-----END CERTIFICATE-----\n'
const v78_srv_cert = '-----BEGIN CERTIFICATE-----\nMIIBvzCCAWSgAwIBAgIUYvYm0VaATGcQ5GR0uSseLDICww0wCgYIKoZIzj0EAwIw\nGTEXMBUGA1UEAwwOY3ggdGVzdCB2NzggY2EwIBcNMjYxMTIwMDgxMjQ3WhgPMjEy\nNjEwMjcwODEyNDdaMBQxEjAQBgNVBAMMCWxvY2FsaG9zdDBZMBMGByqGSM49AgEG\nCCqGSM49AwEHA0IABEUWOIri0i6ug+OFcQmc86WNN6FYsPrRXGBEPxcIWHXYUnHn\nOI8JaxBw08WiJzAOwq2S2rhysGgn7cjxenYKTFCjgYwwgYkwGgYDVR0RBBMwEYIJ\nbG9jYWxob3N0hwR/AAABMAkGA1UdEwQCMAAwCwYDVR0PBAQDAgeAMBMGA1UdJQQM\nMAoGCCsGAQUFBwMBMB0GA1UdDgQWBBRyLfkqna0iFH60ZNF2i2cP6sMPhzAfBgNV\nHSMEGDAWgBQxrTKQUum7Oke3TUG2C1wdrzfg0jAKBggqhkjOPQQDAgNJADBGAiEA\n7fbL1sfGNaGZeb3CvSrSaeGXwD55ZhV5DchMLClbMJcCIQCECU3JNDW99W8lPnBz\ndlLxehyXae9Vs03k5ooKp7E9wA==\n-----END CERTIFICATE-----\n'
const v78_srv_key = '-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEICpSDuJNBxj2/0ZIv4LXjt3QCpal3kGVx4RGocA9uWR5oAoGCCqGSM49\nAwEHoUQDQgAERRY4iuLSLq6D44VxCZzzpY03oViw+tFcYEQ/FwhYddhScec4jwlr\nEHDTxaInMA7CrZLauHKwaCftyPF6dgpMUA==\n-----END EC PRIVATE KEY-----\n'
const v78_cli_cert = '-----BEGIN CERTIFICATE-----\nMIIBqDCCAU+gAwIBAgIUYvYm0VaATGcQ5GR0uSseLDICww4wCgYIKoZIzj0EAwIw\nGTEXMBUGA1UEAwwOY3ggdGVzdCB2NzggY2EwIBcNMjYxMTIwMDgxMjQ4WhgPMjEy\nNjEwMjcwODEyNDhaMB0xGzAZBgNVBAMMEmN4IHRlc3Qgdjc4IGNsaWVudDBZMBMG\nByqGSM49AgEGCCqGSM49AwEHA0IABKZ+Ae48JKT7WsYzzkwXnBFXvQh+HXFT8OZr\n+iBtbYQFto8vDZd4bj1AtyBLL6680nB3H+QcAUJYP3VnBxHvcnWjbzBtMAkGA1Ud\nEwQCMAAwCwYDVR0PBAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMCMB0GA1UdDgQW\nBBS+akj1hKKZ8p9l6OZFT0RV+UaS9zAfBgNVHSMEGDAWgBQxrTKQUum7Oke3TUG2\nC1wdrzfg0jAKBggqhkjOPQQDAgNHADBEAiA6ZspW00MPyjJBEshOS8EZMaWmTNyR\nXKI4oadUWOKQ2gIgMn/O435QjmptJjj74sqrTq2phXfCoT9hw2cX5gAH5j4=\n-----END CERTIFICATE-----\n'
const v78_cli_key = '-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIDFSia++3TwKvbz0G1+IbO0bRQuh6+GFCofiYPo/d4UOoAoGCCqGSM49\nAwEHoUQDQgAEpn4B7jwkpPtaxjPOTBecEVe9CH4dcVPw5mv6IG1thAW2jy8Nl3hu\nPUC3IEsvrrzScHcf5BwBQlg/dWcHEe9ydQ==\n-----END EC PRIVATE KEY-----\n'

fn v78_listener() !&SSLListener {
	mut l := new_ssl_listener('127.0.0.1:0', SSLConnectConfig{
		verify:                 v78_ca
		cert:                   v78_srv_cert
		cert_key:               v78_srv_key
		validate:               false
		in_memory_verification: true
	})!
	// The listener's validate=false leaves VERIFY_NONE (no CertificateRequest);
	// OPTIONAL sends the request and lets the client decline it.
	C.mbedtls_ssl_conf_authmode(&l.conf, C.MBEDTLS_SSL_VERIFY_OPTIONAL)
	return l
}

// serve_one answers one connection and reports whether the peer presented a
// certificate that verified against the listener's CA.
fn v78_serve_one(mut l SSLListener) !string {
	mut conn := l.accept()!
	mut buf := []u8{len: 64}
	n := conn.read(mut buf)!
	peer := C.mbedtls_ssl_get_peer_cert(&conn.ssl)
	flags := C.mbedtls_ssl_get_verify_result(&conn.ssl)
	conn.write_string('pong-v78')!
	conn.shutdown() or {}
	mut who := 'no-client-cert'
	if peer != unsafe { nil } {
		who = if flags == 0 { 'client-cert-verified' } else { 'client-cert-unverified' }
	}
	return '${buf[..n].bytestr()} ${who}'
}

fn v78_round_trip(client_config SSLConnectConfig) !string {
	mut listener := v78_listener()!
	defer {
		listener.shutdown() or {}
	}
	port := listener.addr()!.port()!
	server := spawn v78_serve_one(mut listener)
	mut client := new_ssl_conn(client_config)!
	client.dial('localhost', port) or {
		server.wait() or {}
		return err
	}
	client.write_string('ping-v78')!
	mut rbuf := []u8{len: 64}
	rn := client.read(mut rbuf)!
	assert rbuf[..rn].bytestr() == 'pong-v78'
	client.shutdown() or {}
	return server.wait()!
}

fn test_ca_pinned_client_without_a_cert_answers_an_optional_certificate_request() {
	spawn fn () {
		time.sleep(60 * time.second)
		eprintln('mbedtls optional client cert test: timeout reached, exiting.')
		exit(1)
	}()
	got := v78_round_trip(SSLConnectConfig{
		verify:                 v78_ca
		validate:               true
		in_memory_verification: true
	}) or {
		panic('a client with only `verify` failed the handshake with a server that requests an optional client certificate (cx-home/v#78): ${err}')
	}
	assert got == 'ping-v78 no-client-cert'
}

fn test_client_with_cert_and_key_still_sends_it() {
	got := v78_round_trip(SSLConnectConfig{
		verify:                 v78_ca
		cert:                   v78_cli_cert
		cert_key:               v78_cli_key
		validate:               true
		in_memory_verification: true
	}) or { panic('mutual TLS with a client certificate failed: ${err}') }
	assert got == 'ping-v78 client-cert-verified'
}
