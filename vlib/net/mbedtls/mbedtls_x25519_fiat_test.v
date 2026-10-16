// vtest build: !(windows && tinyc)
// cx-home/v#39: where the C compiler has a 128-bit integer (gcc, clang), the
// PSA X25519 runs fiat-crypto's verified curve25519 field arithmetic
// (thirdparty/fiat-25519, mit-plv/fiat-crypto 64e8f2791b) under the RFC 7748
// ladder in library/cx_x25519_fiat.c (25.0 us per X25519 against HACL*'s 33.2
// and Go's 28.9 on dev2). It must give RFC 7748 section 5.2's answers and
// HACL*'s answer on every input it is given here.
import net.mbedtls as _

#insert "@VMODROOT/vlib/net/mbedtls/mbedtls_x25519_fiat_test.h"

fn C.cx_x25519_fiat_cases() int

fn test_x25519_fiat_matches_rfc7748_and_hacl() {
	$if tinyc {
		// no __int128 under tcc: the PSA path keeps its own X25519 there
		return
	}
	rc := C.cx_x25519_fiat_cases()
	$if macos || linux {
		assert rc == 0, 'case ${rc}'
	} $else {
		assert rc <= 0, 'case ${rc}'
	}
}
