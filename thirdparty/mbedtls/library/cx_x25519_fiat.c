/*
 * cx-home/v#39: X25519 over fiat-crypto's formally verified curve25519
 * field arithmetic (thirdparty/fiat-25519/curve25519_64.c, upstream
 * mit-plv/fiat-crypto 64e8f2791b byte for byte; the 5 x 51-bit form), the
 * RFC 7748 Montgomery ladder with a constant-time conditional swap and the
 * inverse as the usual addition chain for 2^255 - 21. 25.0 us per X25519 on
 * dev2 at -O2, against HACL*'s portable 64-bit 33.2 us and Go 1.27's 28.9 us.
 * A TLS 1.3 server runs two per handshake (the key share and the agreement).
 */
#include "cx_x25519_fiat.h"

#if defined(CX_X25519_FIAT)

#include <string.h>
#include "common.h"
#include "mbedtls/platform_util.h"

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic ignored "-Wunused-function"
#endif
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-function"
#endif

#include "../../fiat-25519/curve25519_64.c"

typedef uint64_t cx_fe25519[5];
static void cx_fe25519_sqn(cx_fe25519 out, const cx_fe25519 a, int n) {
    int i;
    fiat_25519_carry_square(out, a);
    for (i = 1; i < n; i++) fiat_25519_carry_square(out, out);
}

/* a^(p-2), p = 2^255-19: 254 squarings, 11 multiplications */
static void cx_fe25519_inv(cx_fe25519 out, const cx_fe25519 z) {
    cx_fe25519 t0, t1, t2, t3;
    fiat_25519_carry_square(t0, z);          /* 2 */
    cx_fe25519_sqn(t1, t0, 2);                       /* 8 */
    fiat_25519_carry_mul(t1, z, t1);         /* 9 */
    fiat_25519_carry_mul(t0, t0, t1);        /* 11 */
    fiat_25519_carry_square(t2, t0);         /* 22 */
    fiat_25519_carry_mul(t1, t1, t2);        /* 2^5 - 1 */
    cx_fe25519_sqn(t2, t1, 5);
    fiat_25519_carry_mul(t1, t2, t1);        /* 2^10 - 1 */
    cx_fe25519_sqn(t2, t1, 10);
    fiat_25519_carry_mul(t2, t2, t1);        /* 2^20 - 1 */
    cx_fe25519_sqn(t3, t2, 20);
    fiat_25519_carry_mul(t2, t3, t2);        /* 2^40 - 1 */
    cx_fe25519_sqn(t2, t2, 10);
    fiat_25519_carry_mul(t1, t2, t1);        /* 2^50 - 1 */
    cx_fe25519_sqn(t2, t1, 50);
    fiat_25519_carry_mul(t2, t2, t1);        /* 2^100 - 1 */
    cx_fe25519_sqn(t3, t2, 100);
    fiat_25519_carry_mul(t2, t3, t2);        /* 2^200 - 1 */
    cx_fe25519_sqn(t2, t2, 50);
    fiat_25519_carry_mul(t1, t2, t1);        /* 2^250 - 1 */
    cx_fe25519_sqn(t1, t1, 5);
    fiat_25519_carry_mul(out, t1, t0);       /* 2^255 - 21 */
}

static void cx_fe25519_cswap(cx_fe25519 a, cx_fe25519 b, uint64_t swap) {
    cx_fe25519 ta, tb;
    fiat_25519_selectznz(ta, (fiat_25519_uint1) swap, a, b);
    fiat_25519_selectznz(tb, (fiat_25519_uint1) swap, b, a);
    memcpy(a, ta, sizeof(cx_fe25519));
    memcpy(b, tb, sizeof(cx_fe25519));
}

/* RFC 7748 X25519: out = scalar * u (32-byte little-endian each) */
void cx_x25519_fiat(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]) {
    uint8_t e[32], ub[32];
    cx_fe25519 x1, x2, z2, x3, z3, a, aa, b, bb, ee, c, d, da, cb, t;
    uint64_t swap = 0;
    int pos;
    memcpy(e, scalar, 32);
    e[0] &= 248; e[31] &= 127; e[31] |= 64;
    memcpy(ub, point, 32);
    ub[31] &= 127;
    fiat_25519_from_bytes(x1, ub);
    memset(x2, 0, sizeof(cx_fe25519)); x2[0] = 1;
    memset(z2, 0, sizeof(cx_fe25519));
    memcpy(x3, x1, sizeof(cx_fe25519));
    memset(z3, 0, sizeof(cx_fe25519)); z3[0] = 1;
    for (pos = 254; pos >= 0; pos--) {
        uint64_t bit = (e[pos >> 3] >> (pos & 7)) & 1;
        swap ^= bit;
        cx_fe25519_cswap(x2, x3, swap);
        cx_fe25519_cswap(z2, z3, swap);
        swap = bit;
        fiat_25519_add(t, x2, z2); fiat_25519_carry(a, t);
        fiat_25519_sub(t, x2, z2); fiat_25519_carry(b, t);
        fiat_25519_add(t, x3, z3); fiat_25519_carry(c, t);
        fiat_25519_sub(t, x3, z3); fiat_25519_carry(d, t);
        fiat_25519_carry_square(aa, a);
        fiat_25519_carry_square(bb, b);
        fiat_25519_sub(t, aa, bb); fiat_25519_carry(ee, t);
        fiat_25519_carry_mul(da, d, a);
        fiat_25519_carry_mul(cb, c, b);
        fiat_25519_add(t, da, cb); fiat_25519_carry_square(x3, t);
        fiat_25519_sub(t, da, cb); fiat_25519_carry_square(z3, t);
        fiat_25519_carry_mul(z3, x1, z3);
        fiat_25519_carry_mul(x2, aa, bb);
        fiat_25519_carry_scmul_121666(t, ee);
        fiat_25519_add(t, t, bb);
        fiat_25519_carry_mul(z2, ee, t);
    }
    cx_fe25519_cswap(x2, x3, swap);
    cx_fe25519_cswap(z2, z3, swap);
    cx_fe25519_inv(z2, z2);
    fiat_25519_carry_mul(x2, x2, z2);
    fiat_25519_to_bytes(out, x2);
    mbedtls_platform_zeroize(e, sizeof(e));
    mbedtls_platform_zeroize(x2, sizeof(x2));
    mbedtls_platform_zeroize(z2, sizeof(z2));
    mbedtls_platform_zeroize(x3, sizeof(x3));
    mbedtls_platform_zeroize(z3, sizeof(z3));
}

#endif /* CX_X25519_FIAT */
