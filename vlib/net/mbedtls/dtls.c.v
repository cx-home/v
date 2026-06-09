module mbedtls

import io
import net

// dtls.c.v — DTLS-over-UDP for the mbedTLS wrapper (cx-stdlib/net §3.6a).
//
// The TLS surface in ssl_connection.c.v is stream-only (TCP). This file adds the
// datagram counterpart: a DTLS client (DTLSConn.dial) and a DTLS server
// (DTLSListener.accept) with the MANDATORY RFC 6347 HelloVerifyRequest stateless
// cookie exchange. It mirrors the canonical mbedTLS dtls_client.c / dtls_server.c
// samples and reuses the wrapper's existing RNG/cert helpers + SSLConnectConfig.
//
// Three mbedTLS facilities beyond the TLS path:
//   - MBEDTLS_SSL_TRANSPORT_DATAGRAM in ssl_config_defaults (vs _STREAM).
//   - a retransmission timer (set_timer_cb + the timing module) — REQUIRED for
//     DTLS; the handshake fails without it.
//   - the cookie callbacks (conf_dtls_cookies + a per-listener cookie ctx) and
//     set_client_transport_id, so the server emits/verifies HelloVerifyRequest.

#include <mbedtls/ssl_cookie.h>
#include <mbedtls/timing.h>

@[typedef]
pub struct C.mbedtls_ssl_cookie_ctx {}

@[typedef]
pub struct C.mbedtls_timing_delay_context {}

fn C.mbedtls_ssl_cookie_init(&C.mbedtls_ssl_cookie_ctx)
fn C.mbedtls_ssl_cookie_setup(&C.mbedtls_ssl_cookie_ctx, fn (voidptr, &u8, usize) int, voidptr) int
fn C.mbedtls_ssl_cookie_free(&C.mbedtls_ssl_cookie_ctx)

// the canonical cookie write/check callbacks (passed by reference to conf_dtls_cookies)
fn C.mbedtls_ssl_cookie_write(voidptr, &&u8, &u8, &u8, usize) int
fn C.mbedtls_ssl_cookie_check(voidptr, &u8, usize, &u8, usize) int

fn C.mbedtls_ssl_conf_dtls_cookies(&C.mbedtls_ssl_config, fn (voidptr, &&u8, &u8, &u8, usize) int, fn (voidptr, &u8, usize, &u8, usize) int, voidptr)
fn C.mbedtls_ssl_set_client_transport_id(&C.mbedtls_ssl_context, &u8, usize) int

fn C.mbedtls_ssl_set_timer_cb(&C.mbedtls_ssl_context, voidptr, fn (voidptr, u32, u32), fn (voidptr) int)
fn C.mbedtls_timing_set_delay(voidptr, u32, u32)
fn C.mbedtls_timing_get_delay(voidptr) int
fn C.mbedtls_ssl_conf_handshake_timeout(&C.mbedtls_ssl_config, u32, u32)

// dtls_apply_handshake_timeout bounds the DTLS handshake retransmission window
// when the caller asked for it (config.dtls_handshake_max_ms > 0). Default 0 ⇒
// leave the mbedTLS / RFC 6347 default (1 s … 60 s) untouched — a bound is opt-in
// so a dial against an unbound peer can fail fast (used by hermetic tests),
// without changing production retransmit behavior.
fn dtls_apply_handshake_timeout(conf &C.mbedtls_ssl_config, config SSLConnectConfig) {
	if config.dtls_handshake_max_ms == 0 {
		return
	}
	mut min_ms := config.dtls_handshake_min_ms
	if min_ms == 0 || min_ms > config.dtls_handshake_max_ms {
		min_ms = config.dtls_handshake_max_ms
	}
	C.mbedtls_ssl_conf_handshake_timeout(conf, min_ms, config.dtls_handshake_max_ms)
}

// DTLSConn is a secured datagram socket — a connected DTLS client, or a per-peer
// socket handed back by DTLSListener.accept. It carries the §3.5 datagram verbs
// (read/write == one DTLS record), never the stream verbs.
pub struct DTLSConn {
pub:
	config SSLConnectConfig
pub mut:
	server_fd C.mbedtls_net_context
	ssl       C.mbedtls_ssl_context
	conf      C.mbedtls_ssl_config
	timer     C.mbedtls_timing_delay_context
	certs     &SSLCerts = unsafe { nil }
	ctr_drbg  C.mbedtls_ctr_drbg_context
	entropy   C.mbedtls_entropy_context
	handle    int
	opened    bool
	// a client owns its config + rng (built here); an accepted peer socket shares
	// the listener's config, so it must not free them on close.
	owns_conf   bool
	owns_socket bool
}

// DTLSListener binds a UDP socket and accepts DTLS peers behind a stateless
// HelloVerifyRequest cookie. The config/cookie-ctx/rng persist for the listener's
// lifetime because each accepted DTLSConn's ssl is set up against this conf.
pub struct DTLSListener {
	saddr  string
	config SSLConnectConfig
mut:
	server_fd  C.mbedtls_net_context
	conf       C.mbedtls_ssl_config
	cookie_ctx C.mbedtls_ssl_cookie_ctx
	certs      &SSLCerts = unsafe { nil }
	ctr_drbg   C.mbedtls_ctr_drbg_context
	entropy    C.mbedtls_entropy_context
	opened     bool
}

// new_dtls_client builds a DTLS client context (datagram transport + timer); call
// dial() to connect the UDP socket and run the handshake.
pub fn new_dtls_client(config SSLConnectConfig) !&DTLSConn {
	mut c := &DTLSConn{
		config:       config
		owns_conf:     true
		owns_socket:   true
	}
	C.mbedtls_net_init(&c.server_fd)
	C.mbedtls_ssl_init(&c.ssl)
	C.mbedtls_ssl_config_init(&c.conf)
	init_rng(mut c.ctr_drbg, mut c.entropy)!

	mut ret := C.mbedtls_ssl_config_defaults(&c.conf, C.MBEDTLS_SSL_IS_CLIENT,
		C.MBEDTLS_SSL_TRANSPORT_DATAGRAM, C.MBEDTLS_SSL_PRESET_DEFAULT)
	if ret != 0 {
		return error_with_code('net.mbedtls DTLSConn, config_defaults ret: ${ret}', ret)
	}
	unsafe {
		C.mbedtls_ssl_conf_rng(&c.conf, C.mbedtls_ctr_drbg_random, &c.ctr_drbg)
	}
	dtls_apply_handshake_timeout(&c.conf, c.config)

	if c.config.verify != '' || c.config.cert != '' || c.config.cert_key != '' {
		c.certs = if c.config.in_memory_verification {
			new_sslcerts_in_memory_with_rng(c.config.verify, c.config.cert, c.config.cert_key,
				&c.ctr_drbg) or {
				return error('net.mbedtls DTLSConn, cert failure (in-memory): ${err}')
			}
		} else {
			new_sslcerts_from_file_with_rng(c.config.verify, c.config.cert, c.config.cert_key,
				&c.ctr_drbg) or {
				return error('net.mbedtls DTLSConn, cert failure (file): ${err}')
			}
		}
		C.mbedtls_ssl_conf_ca_chain(&c.conf, &c.certs.cacert, unsafe { nil })
		C.mbedtls_ssl_conf_own_cert(&c.conf, &c.certs.client_cert, &c.certs.client_key)
	}

	if c.config.validate {
		C.mbedtls_ssl_conf_authmode(&c.conf, C.MBEDTLS_SSL_VERIFY_REQUIRED)
	} else {
		C.mbedtls_ssl_conf_authmode(&c.conf, C.MBEDTLS_SSL_VERIFY_OPTIONAL)
	}

	// bound the app read so a stuck peer surfaces a timeout instead of hanging;
	// the handshake retransmit timer (set_timer_cb) drives its own intervals.
	C.mbedtls_ssl_conf_read_timeout(&c.conf, ssl_read_timeout_ms(c.config.read_timeout))

	ret = C.mbedtls_ssl_setup(&c.ssl, &c.conf)
	if ret != 0 {
		return error_with_code('net.mbedtls DTLSConn, ssl_setup ret: ${ret}', ret)
	}
	C.mbedtls_ssl_set_timer_cb(&c.ssl, &c.timer, C.mbedtls_timing_set_delay, C.mbedtls_timing_get_delay)
	return c
}

// dial opens a connected UDP socket to hostname:port and runs the DTLS handshake.
pub fn (mut c DTLSConn) dial(hostname string, port int) ! {
	if c.opened {
		return error('net.mbedtls DTLSConn.dial, already open')
	}
	mut ret := C.mbedtls_ssl_set_hostname(&c.ssl, &char(hostname.str))
	if ret != 0 {
		return error_with_code('net.mbedtls DTLSConn.dial, set_hostname ret: ${ret}', ret)
	}
	port_str := port.str()
	ret = C.mbedtls_net_connect(&c.server_fd, &char(hostname.str), &char(port_str.str),
		C.MBEDTLS_NET_PROTO_UDP)
	if ret != 0 {
		return error_with_code('net.mbedtls DTLSConn.dial, net_connect ret: ${ret}', ret)
	}
	c.handle = c.server_fd.fd
	C.mbedtls_ssl_set_bio(&c.ssl, &c.server_fd, C.mbedtls_net_send, C.mbedtls_net_recv,
		C.mbedtls_net_recv_timeout)

	mut hret := C.mbedtls_ssl_handshake(&c.ssl)
	for hret == C.MBEDTLS_ERR_SSL_WANT_READ || hret == C.MBEDTLS_ERR_SSL_WANT_WRITE {
		hret = C.mbedtls_ssl_handshake(&c.ssl)
	}
	if hret != 0 {
		return error_with_code('net.mbedtls DTLSConn.dial, handshake ret: ${hret}', hret)
	}
	c.opened = true
}

// read reads one DTLS record (up to buffer.len bytes) — one received datagram.
pub fn (mut c DTLSConn) read(mut buffer []u8) !int {
	for {
		res := C.mbedtls_ssl_read(&c.ssl, &u8(buffer.data), buffer.len)
		if res > 0 {
			return res
		}
		if res == 0 {
			return io.Eof{}
		}
		match res {
			C.MBEDTLS_ERR_SSL_WANT_READ, C.MBEDTLS_ERR_SSL_WANT_WRITE {
				continue
			}
			C.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY {
				return 0
			}
			C.MBEDTLS_ERR_SSL_TIMEOUT {
				return error_with_code('net.mbedtls DTLSConn.read, timeout', res)
			}
			else {
				return error_with_code('net.mbedtls DTLSConn.read, ret: ${res}', res)
			}
		}
	}
	return 0
}

// write sends one DTLS record (one datagram).
pub fn (mut c DTLSConn) write(data []u8) !int {
	for {
		res := C.mbedtls_ssl_write(&c.ssl, &u8(data.data), data.len)
		if res >= 0 {
			return res
		}
		match res {
			C.MBEDTLS_ERR_SSL_WANT_READ, C.MBEDTLS_ERR_SSL_WANT_WRITE {
				continue
			}
			else {
				return error_with_code('net.mbedtls DTLSConn.write, ret: ${res}', res)
			}
		}
	}
	return 0
}

// close tears down the DTLS socket. A client frees its own config/rng/certs; an
// accepted peer socket shares the listener's config and only frees its own ssl/fd.
pub fn (mut c DTLSConn) close() ! {
	if !c.opened {
		return
	}
	c.opened = false
	C.mbedtls_ssl_free(&c.ssl)
	if c.owns_conf {
		C.mbedtls_ssl_config_free(&c.conf)
		free_rng(mut c.ctr_drbg, mut c.entropy)
		if unsafe { c.certs != nil } {
			c.certs.cleanup()
			c.certs = unsafe { nil }
		}
	}
	if c.owns_socket {
		C.mbedtls_net_free(&c.server_fd)
	}
}

// addr / peer_addr expose the bound + peer addresses for net's local-addr / remote-addr.
pub fn (c &DTLSConn) addr() !net.Addr {
	return net.addr_from_socket_handle(c.handle)
}

pub fn (c &DTLSConn) peer_addr() !net.Addr {
	return net.peer_addr_from_socket_handle(c.handle)
}

// new_dtls_listener binds a UDP socket and configures the DTLS server identity +
// the stateless cookie machinery (HelloVerifyRequest).
pub fn new_dtls_listener(saddr string, config SSLConnectConfig) !&DTLSListener {
	mut l := &DTLSListener{
		saddr:  saddr
		config: config
	}
	l.init()!
	l.opened = true
	return l
}

fn (mut l DTLSListener) init() ! {
	lhost, lport := net.split_address(l.saddr)!
	if l.config.cert == '' || l.config.cert_key == '' {
		return error('net.mbedtls DTLSListener.init, no certificate or key provided')
	}
	C.mbedtls_net_init(&l.server_fd)
	C.mbedtls_ssl_config_init(&l.conf)
	C.mbedtls_ssl_cookie_init(&l.cookie_ctx)
	init_rng(mut l.ctr_drbg, mut l.entropy)!

	unsafe {
		C.mbedtls_ssl_conf_rng(&l.conf, C.mbedtls_ctr_drbg_random, &l.ctr_drbg)
	}

	l.certs = if l.config.in_memory_verification {
		new_sslcerts_in_memory_with_rng(l.config.verify, l.config.cert, l.config.cert_key,
			&l.ctr_drbg) or {
			return error('net.mbedtls DTLSListener.init, cert failure (in-memory): ${err}')
		}
	} else {
		new_sslcerts_from_file_with_rng(l.config.verify, l.config.cert, l.config.cert_key,
			&l.ctr_drbg) or {
			return error('net.mbedtls DTLSListener.init, cert failure (file): ${err}')
		}
	}

	// bind the UDP listening socket
	mut bind_ip := unsafe { nil }
	if lhost != '' {
		bind_ip = voidptr(lhost.str)
	}
	bind_port := lport.str()
	mut ret := C.mbedtls_net_bind(&l.server_fd, bind_ip, voidptr(bind_port.str), C.MBEDTLS_NET_PROTO_UDP)
	if ret != 0 {
		return error_with_code("net.mbedtls DTLSListener.init, net_bind can't bind ${l.saddr} ret: ${ret}",
			ret)
	}

	ret = C.mbedtls_ssl_config_defaults(&l.conf, C.MBEDTLS_SSL_IS_SERVER, C.MBEDTLS_SSL_TRANSPORT_DATAGRAM,
		C.MBEDTLS_SSL_PRESET_DEFAULT)
	if ret != 0 {
		return error_with_code('net.mbedtls DTLSListener.init, config_defaults ret: ${ret}',
			ret)
	}

	dtls_apply_handshake_timeout(&l.conf, l.config)

	C.mbedtls_ssl_conf_ca_chain(&l.conf, &l.certs.cacert, unsafe { nil })
	ret = C.mbedtls_ssl_conf_own_cert(&l.conf, &l.certs.client_cert, &l.certs.client_key)
	if ret != 0 {
		return error_with_code('net.mbedtls DTLSListener.init, conf_own_cert ret: ${ret}',
			ret)
	}

	// mandatory stateless cookie (anti-amplification, §3.6a/H3): generate keys +
	// wire the HelloVerifyRequest write/check callbacks against the cookie ctx.
	ret = C.mbedtls_ssl_cookie_setup(&l.cookie_ctx, C.mbedtls_ctr_drbg_random, &l.ctr_drbg)
	if ret != 0 {
		return error_with_code('net.mbedtls DTLSListener.init, cookie_setup ret: ${ret}',
			ret)
	}
	C.mbedtls_ssl_conf_dtls_cookies(&l.conf, C.mbedtls_ssl_cookie_write, C.mbedtls_ssl_cookie_check,
		&l.cookie_ctx)

	// mTLS: require a client cert only when a CA was supplied.
	if l.config.validate {
		C.mbedtls_ssl_conf_authmode(&l.conf, C.MBEDTLS_SSL_VERIFY_REQUIRED)
	}
}

// accept blocks for one DTLS peer, completing the mandatory HelloVerifyRequest
// cookie exchange before the per-peer handshake state is finalised. The
// HELLO_VERIFY_REQUIRED loop is the cookie round-trip: the first cookieless
// ClientHello draws a HelloVerifyRequest, and the cookie-bearing retransmission
// (delivered to the re-bound listening socket) completes the handshake.
pub fn (mut l DTLSListener) accept() !&DTLSConn {
	mut conn := &DTLSConn{
		config:      l.config
		owns_conf:   false // shares the listener's conf/rng/certs
		owns_socket: true
	}
	C.mbedtls_net_init(&conn.server_fd)
	C.mbedtls_ssl_init(&conn.ssl)
	mut ret := C.mbedtls_ssl_setup(&conn.ssl, &l.conf)
	if ret != 0 {
		return error_with_code('net.mbedtls DTLSListener.accept, ssl_setup ret: ${ret}', ret)
	}
	C.mbedtls_ssl_set_timer_cb(&conn.ssl, &conn.timer, C.mbedtls_timing_set_delay, C.mbedtls_timing_get_delay)

	for {
		C.mbedtls_net_free(&conn.server_fd)
		C.mbedtls_ssl_session_reset(&conn.ssl)

		client_ip := [16]u8{}
		cliip_len := usize(0)
		ret = C.mbedtls_net_accept(&l.server_fd, &conn.server_fd, &client_ip[0], 16, &cliip_len)
		if ret != 0 {
			return error_with_code('net.mbedtls DTLSListener.accept, net_accept ret: ${ret}',
				ret)
		}

		// bind the cookie to this client's transport address (HelloVerifyRequest)
		ret = C.mbedtls_ssl_set_client_transport_id(&conn.ssl, &client_ip[0], cliip_len)
		if ret != 0 {
			return error_with_code('net.mbedtls DTLSListener.accept, set_client_transport_id ret: ${ret}',
				ret)
		}

		C.mbedtls_ssl_set_bio(&conn.ssl, &conn.server_fd, C.mbedtls_net_send, C.mbedtls_net_recv,
			C.mbedtls_net_recv_timeout)

		mut hret := C.mbedtls_ssl_handshake(&conn.ssl)
		for hret == C.MBEDTLS_ERR_SSL_WANT_READ || hret == C.MBEDTLS_ERR_SSL_WANT_WRITE {
			hret = C.mbedtls_ssl_handshake(&conn.ssl)
		}
		if hret == C.MBEDTLS_ERR_SSL_HELLO_VERIFY_REQUIRED {
			// cookie not yet present — the client will retransmit with it. Reset
			// and accept again (the canonical mbedTLS DTLS-server reset loop).
			continue
		}
		if hret != 0 {
			return error_with_code('net.mbedtls DTLSListener.accept, handshake ret: ${hret}',
				hret)
		}
		break
	}
	conn.opened = true
	conn.handle = conn.server_fd.fd
	return conn
}

// shutdown frees the listener resources.
pub fn (mut l DTLSListener) shutdown() ! {
	if unsafe { l.certs != nil } {
		l.certs.cleanup()
		l.certs = unsafe { nil }
	}
	C.mbedtls_ssl_cookie_free(&l.cookie_ctx)
	C.mbedtls_ssl_config_free(&l.conf)
	free_rng(mut l.ctr_drbg, mut l.entropy)
	if l.opened {
		C.mbedtls_net_free(&l.server_fd)
	}
}
