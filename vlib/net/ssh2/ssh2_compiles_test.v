// A session can be created and closed without a peer: the libssh2 objects
// compile against the bundled mbedTLS and link.
import net.ssh2

fn test_a_session_opens_and_closes_without_a_peer() {
	mut s := ssh2.new_session(1000)!
	assert s.is_open()
	s.prefer(ssh2.method_kex, 'ecdh-sha2-nistp256')!
	s.close()
	assert !s.is_open()
	s.close()
}

fn test_an_ec_key_that_is_not_pem_is_refused_before_the_wire() {
	mut s := ssh2.new_session(1000)!
	defer {
		s.close()
	}
	// no socket: the call must fail inside libssh2, never crash
	s.auth_public_key('u', 'not a key', '') or { return }
	assert false, 'an unauthenticated session accepted a key'
}
