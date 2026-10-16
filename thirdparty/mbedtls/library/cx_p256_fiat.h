/*
 * cx-home/v#39: P-256 ECDSA signing over fiat-crypto's verified field and
 * scalar arithmetic (thirdparty/fiat-p256, ECSIG-1). ecdsa.c's
 * mbedtls_ecdsa_sign_restartable takes this path for secp256r1 whenever no
 * restart context is in play; everything else keeps the builtin.
 *
 * Only where the compiler has a 128-bit integer (fiat's 64-bit code needs
 * it): not under tcc, not under msvc, which keep the builtin comb.
 */
#ifndef CX_P256_FIAT_H
#define CX_P256_FIAT_H

#include "common.h"

#if defined(MBEDTLS_ECDSA_C) && defined(MBEDTLS_ECP_DP_SECP256R1_ENABLED) && !defined(CX_P256_FIAT_OFF) && \
    !defined(__TINYC__) && defined(__SIZEOF_INT128__) && (__SIZEOF_INT128__ == 16) && \
    (defined(__GNUC__) || defined(__clang__))
#define CX_P256_FIAT 1

/* x (and y) of k*G, big-endian, for 1 <= k < n (k big-endian, 32 bytes).
 * Constant time in k. Returns 0, or -1 when k is 0 or not below n. */
int cx_p256_fiat_mul_base(unsigned char x[32], unsigned char y[32],
                          const unsigned char k[32]);

/* s = k^-1 * (e + r * d) mod n, every value big-endian, 32 bytes, each
 * below n (k nonzero). Constant time in k and d. */
void cx_p256_fiat_sign_s(unsigned char s[32], const unsigned char k[32],
                         const unsigned char r[32], const unsigned char d[32],
                         const unsigned char e[32]);
#endif

#endif /* CX_P256_FIAT_H */
