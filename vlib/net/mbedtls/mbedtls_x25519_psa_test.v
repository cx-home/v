// vtest build: !(windows && tinyc)
// cx-home/v#39: TLS 1.3's X25519 runs through PSA; the builtin's generic
// Montgomery ladder over mbedtls_mpi was 75 % of a server handshake's CPU.
// The PSA path now runs HACL* Curve25519 (thirdparty/mbedtls/library/
// cx_x25519_hacl.c): the RFC 7748 vectors must agree, a small-order peer point
// must be refused, and the agreement must cost well under the ladder's time,
// measured interleaved in this process (the least of five rounds each).
import net.mbedtls as _

#insert "@VMODROOT/vlib/net/mbedtls/mbedtls_x25519_psa_test.h"

fn C.cx_x25519_vectors() int
fn C.cx_x25519_speed_ratio(rounds int, per int, psa_us &f64, ladder_us &f64) f64

fn test_x25519_psa_matches_rfc7748() {
	assert C.cx_x25519_vectors() == 0
}

fn test_x25519_psa_is_faster_than_the_generic_ladder() {
	$if tinyc {
		// tcc cannot compile kremlin's code: the PSA path keeps the ladder there
		return
	}
	mut p := 0.0
	mut l := 0.0
	ratio := C.cx_x25519_speed_ratio(5, 200, &p, &l)
	println('x25519 psa ${p:.1f} us, generic ladder ${l:.1f} us, ratio ${ratio:.3f}')
	assert ratio > 0
	assert ratio < 0.6, 'PSA X25519 ${p:.1f} us vs the generic ladder ${l:.1f} us'
}
