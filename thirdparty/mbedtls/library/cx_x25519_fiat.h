/*
 * cx-home/v#39: X25519 over fiat-crypto's verified curve25519 field
 * arithmetic (thirdparty/fiat-25519: mit-plv/fiat-crypto 64e8f2791b), the
 * RFC 7748 ladder in library/cx_x25519_fiat.c. psa_crypto_ecp.c's X25519
 * takes it where the compiler has a 128-bit integer (gcc, clang: not tcc,
 * not msvc); HACL* (cx_x25519_hacl.c) stays the X25519 elsewhere.
 */
#ifndef CX_X25519_FIAT_H
#define CX_X25519_FIAT_H

#include <stdint.h>

#if !defined(__TINYC__) && defined(__SIZEOF_INT128__) && (__SIZEOF_INT128__ == 16) && \
    (defined(__GNUC__) || defined(__clang__)) && !defined(CX_X25519_FIAT_OFF)
#define CX_X25519_FIAT 1
/* out = X25519(scalar, point): RFC 7748 section 5, 32-byte little-endian
 * each; the scalar is clamped and the u-coordinate's top bit masked inside.
 * Constant time in the scalar. */
void cx_x25519_fiat(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]);
#endif

#endif /* CX_X25519_FIAT_H */
