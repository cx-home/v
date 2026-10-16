// vtest build: !(windows && tinyc)
// cx-home/v#39: a TLS server's P-256 ECDSA signature (CertificateVerify) ran
// through the builtin comb over mbedtls_mpi and two mbedtls_mpi inversions:
// 53 % of a cx server's busy handshake samples. secp256r1 now signs over
// fiat-crypto's verified arithmetic (thirdparty/mbedtls/library/
// cx_p256_fiat.c, the field and scalar of thirdparty/fiat-p256): k*G must equal
// mbedtls_ecp_mul's for edge and random scalars, RFC 6979 A.2.5's signatures
// must come out byte for byte, every signature must verify, and a whole
// signature must cost well under the builtin comb's k*G alone, measured
// interleaved in this process (the least of five rounds each).
import net.mbedtls as _

#insert "@VMODROOT/vlib/net/mbedtls/mbedtls_p256_fiat_test.h"

fn C.cx_p256_mul_base_agrees(random_cases int) int
fn C.cx_p256_rfc6979() int
fn C.cx_p256_sign_verify(cases int) int
fn C.cx_p256_sign_speed_ratio(rounds int, per int, sign_us &f64, comb_us &f64) f64

fn test_p256_fiat_mul_base_matches_mbedtls() {
	assert C.cx_p256_mul_base_agrees(500) == 0
}

fn test_p256_deterministic_signatures_match_rfc6979() {
	assert C.cx_p256_rfc6979() == 0
}

fn test_p256_signatures_verify() {
	assert C.cx_p256_sign_verify(200) == 0
}

fn test_p256_sign_is_faster_than_the_builtin_comb() {
	$if tinyc || msvc {
		// no 128-bit integer for fiat's 64-bit code: the builtin signs there
		return
	}
	$if !prod {
		// V compiles thirdparty C unoptimised outside -prod, and fiat's code is
		// written for the optimiser (cx ships -prod builds): this is a -prod row
		println('p256 sign speed: a -prod row, skipped')
		return
	}
	mut s := 0.0
	mut c := 0.0
	ratio := C.cx_p256_sign_speed_ratio(5, 100, &s, &c)
	println('p256 ecdsa sign ${s:.1f} us, builtin comb k*G ${c:.1f} us, ratio ${ratio:.3f}')
	assert ratio > 0
	assert ratio < 0.5, 'P-256 sign ${s:.1f} us vs the builtin comb k*G ${c:.1f} us'
}
