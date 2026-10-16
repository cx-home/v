/*
 * cx-home/v#39: P-256 ECDSA signing over fiat-crypto's formally verified,
 * constant-time field and scalar arithmetic (thirdparty/fiat-p256: upstream
 * mit-plv/fiat-crypto 64e8f2791b, ECSIG-1). The builtin signs through
 * ecp_mul_comb over mbedtls_mpi and two mbedtls_mpi inversions (the k^-1 and
 * the Jacobian normalize): 53 % of a cx TLS server's busy samples.
 *
 * k*G is a fixed-base window of 4 bits over a table of j * 16^i * G
 * (i = 0..63, j = 1..15, affine, Montgomery form), built once per process:
 * 64 mixed additions and no doublings per signature. Each window's point is
 * read by a full constant-time scan of its 15 entries, a zero window and the
 * point at infinity are selected by masks, never by branches. No addition
 * can meet the doubling case: after window i the accumulator is m*G with
 * m < 16^i, and the window adds c * 16^i * G (1 <= c <= 15) with
 * m + c * 16^i <= k < n, so it is never +-m*G.
 *
 * Inversions are Fermat powers by the public exponents p-2 (an addition
 * chain) and n-2 (a fixed 4-bit window).
 */
#include "cx_p256_fiat.h"

#if defined(CX_P256_FIAT)

#include <stdint.h>
#include <string.h>
#include "mbedtls/platform_util.h"

#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic ignored "-Wunused-function"
#endif
#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-function"
#endif

#include "../../fiat-p256/p256_64.c"
#include "../../fiat-p256/p256_scalar_64.c"

typedef uint64_t cx_fe[4];

typedef struct {
    cx_fe x, y;
} cx_p256_aff;

typedef struct {
    cx_fe x, y, z;
} cx_p256_jac;

/* ---- field helpers (Montgomery domain mod p) ---------------------------- */

static void cx_fe_copy(cx_fe out, const cx_fe a)
{
    memcpy(out, a, sizeof(cx_fe));
}

/* out = c ? a : out, c in {0, 1} */
static void cx_fe_cmov(cx_fe out, uint64_t c, const cx_fe a)
{
    fiat_p256_selectznz(out, (fiat_p256_uint1) c, out, a);
}

/* 1 when a == 0 (mod p, a fully reduced), else 0; constant time */
static uint64_t cx_fe_is_zero(const cx_fe a)
{
    uint64_t nz;
    fiat_p256_nonzero(&nz, a);
    return ((nz | (0 - nz)) >> 63) ^ 1;
}

static void cx_fe_from_be(cx_fe out, const unsigned char b[32])
{
    uint8_t le[32];
    cx_fe t;
    int i;
    for (i = 0; i < 32; i++) {
        le[i] = b[31 - i];
    }
    fiat_p256_from_bytes(t, le);
    fiat_p256_to_montgomery(out, t);
}

static void cx_fe_to_be(unsigned char b[32], const cx_fe a)
{
    uint8_t le[32];
    cx_fe t;
    int i;
    fiat_p256_from_montgomery(t, a);
    fiat_p256_to_bytes(le, t);
    for (i = 0; i < 32; i++) {
        b[i] = le[31 - i];
    }
}

/* n - 2 */
static const uint64_t cx_n_minus_2[4] = {
    0xf3b9cac2fc63254fULL, 0xbce6faada7179e84ULL,
    0xffffffffffffffffULL, 0xffffffff00000000ULL
};

static void cx_fe_sqn(cx_fe out, const cx_fe a, int n)
{
    int i;
    fiat_p256_square(out, a);
    for (i = 1; i < n; i++) {
        fiat_p256_square(out, out);
    }
}

/* a^(p-2) by an addition chain: 255 squarings and 12 multiplications (the
 * plain square-and-multiply over p-2 takes 127). p-2 from the top: 32 ones,
 * 31 zeros, a one, 96 zeros, 94 ones, a zero, a one. */
static void cx_fe_inv(cx_fe out, const cx_fe a)
{
    cx_fe x2, x3, x6, x12, x15, x30, x32, t;
    fiat_p256_square(t, a);
    fiat_p256_mul(x2, t, a);           /* 2^2 - 1 */
    fiat_p256_square(t, x2);
    fiat_p256_mul(x3, t, a);           /* 2^3 - 1 */
    cx_fe_sqn(t, x3, 3);
    fiat_p256_mul(x6, t, x3);          /* 2^6 - 1 */
    cx_fe_sqn(t, x6, 6);
    fiat_p256_mul(x12, t, x6);         /* 2^12 - 1 */
    cx_fe_sqn(t, x12, 3);
    fiat_p256_mul(x15, t, x3);         /* 2^15 - 1 */
    cx_fe_sqn(t, x15, 15);
    fiat_p256_mul(x30, t, x15);        /* 2^30 - 1 */
    cx_fe_sqn(t, x30, 2);
    fiat_p256_mul(x32, t, x2);         /* 2^32 - 1: the top 32 ones */
    cx_fe_sqn(t, x32, 32);
    fiat_p256_mul(t, t, a);            /* 31 zeros, a one */
    cx_fe_sqn(t, t, 96);               /* 96 zeros */
    cx_fe_sqn(t, t, 32);
    fiat_p256_mul(t, t, x32);
    cx_fe_sqn(t, t, 32);
    fiat_p256_mul(t, t, x32);
    cx_fe_sqn(t, t, 30);
    fiat_p256_mul(t, t, x30);          /* 94 ones */
    cx_fe_sqn(t, t, 2);
    fiat_p256_mul(out, t, a);          /* a zero, a one */
}

/* ---- points ------------------------------------------------------------- */

/* dbl-2001-b (a = -3); in and out may alias */
static void cx_p256_dbl(cx_p256_jac *out, const cx_p256_jac *in)
{
    cx_fe delta, gamma, beta, alpha, t0, t1, x3, y3, z3;
    fiat_p256_square(delta, in->z);
    fiat_p256_square(gamma, in->y);
    fiat_p256_mul(beta, in->x, gamma);
    fiat_p256_sub(t0, in->x, delta);
    fiat_p256_add(t1, in->x, delta);
    fiat_p256_mul(t0, t0, t1);
    fiat_p256_add(alpha, t0, t0);
    fiat_p256_add(alpha, alpha, t0);              /* alpha = 3 (x - d)(x + d) */
    fiat_p256_add(t0, beta, beta);
    fiat_p256_add(t0, t0, t0);                    /* 4 beta */
    fiat_p256_square(x3, alpha);
    fiat_p256_sub(x3, x3, t0);
    fiat_p256_sub(x3, x3, t0);                    /* alpha^2 - 8 beta */
    fiat_p256_add(z3, in->y, in->z);
    fiat_p256_square(z3, z3);
    fiat_p256_sub(z3, z3, gamma);
    fiat_p256_sub(z3, z3, delta);                 /* (y + z)^2 - gamma - delta */
    fiat_p256_sub(t0, t0, x3);
    fiat_p256_mul(y3, alpha, t0);
    fiat_p256_square(t1, gamma);
    fiat_p256_add(t1, t1, t1);
    fiat_p256_add(t1, t1, t1);
    fiat_p256_add(t1, t1, t1);                    /* 8 gamma^2 */
    fiat_p256_sub(y3, y3, t1);
    cx_fe_copy(out->x, x3);
    cx_fe_copy(out->y, y3);
    cx_fe_copy(out->z, z3);
}

/* madd-2007-bl: out = a + b (b affine). Not for a = +-b; the result is
 * garbage when a is the point at infinity (z = 0) and the caller selects.
 * out and a may alias. */
static void cx_p256_madd(cx_p256_jac *out, const cx_p256_jac *a, const cx_p256_aff *b)
{
    cx_fe z1z1, u2, s2, h, hh, i, j, rr, v, x3, y3, z3, t;
    fiat_p256_square(z1z1, a->z);
    fiat_p256_mul(u2, b->x, z1z1);
    fiat_p256_mul(s2, b->y, a->z);
    fiat_p256_mul(s2, s2, z1z1);
    fiat_p256_sub(h, u2, a->x);
    fiat_p256_square(hh, h);
    fiat_p256_add(i, hh, hh);
    fiat_p256_add(i, i, i);                       /* 4 hh */
    fiat_p256_mul(j, h, i);
    fiat_p256_sub(rr, s2, a->y);
    fiat_p256_add(rr, rr, rr);
    fiat_p256_mul(v, a->x, i);
    fiat_p256_square(x3, rr);
    fiat_p256_sub(x3, x3, j);
    fiat_p256_sub(x3, x3, v);
    fiat_p256_sub(x3, x3, v);
    fiat_p256_sub(t, v, x3);
    fiat_p256_mul(y3, rr, t);
    fiat_p256_mul(t, a->y, j);
    fiat_p256_add(t, t, t);
    fiat_p256_sub(y3, y3, t);
    fiat_p256_add(z3, a->z, h);
    fiat_p256_square(z3, z3);
    fiat_p256_sub(z3, z3, z1z1);
    fiat_p256_sub(z3, z3, hh);
    cx_fe_copy(out->x, x3);
    cx_fe_copy(out->y, y3);
    cx_fe_copy(out->z, z3);
}

/* ---- the fixed-base table ------------------------------------------------ */

static const unsigned char cx_p256_gx[32] = {
    0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5, 0x63, 0xa4, 0x40, 0xf2,
    0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96
};
static const unsigned char cx_p256_gy[32] = {
    0x4f, 0xe3, 0x42, 0xe2, 0xfe, 0x1a, 0x7f, 0x9b, 0x8e, 0xe7, 0xeb, 0x4a, 0x7c, 0x0f, 0x9e, 0x16,
    0x2b, 0xce, 0x33, 0x57, 0x6b, 0x31, 0x5e, 0xce, 0xcb, 0xb6, 0x40, 0x68, 0x37, 0xbf, 0x51, 0xf5
};

/* cx_p256_table[i][j - 1] = j * 16^i * G */
static cx_p256_aff cx_p256_table[64][15];
static int cx_p256_table_state;  /* 0 unbuilt, 1 building, 2 built */

/* the 16 points of one row to affine with one inversion (Montgomery's trick) */
static void cx_p256_row_to_affine(cx_p256_aff *out, const cx_p256_jac *in, int n)
{
    cx_fe prefix[16], inv, zinv, zinv2;
    int k;
    cx_fe_copy(prefix[0], in[0].z);
    for (k = 1; k < n; k++) {
        fiat_p256_mul(prefix[k], prefix[k - 1], in[k].z);
    }
    cx_fe_inv(inv, prefix[n - 1]);
    for (k = n - 1; k >= 0; k--) {
        if (k > 0) {
            fiat_p256_mul(zinv, inv, prefix[k - 1]);
            fiat_p256_mul(inv, inv, in[k].z);
        } else {
            cx_fe_copy(zinv, inv);
        }
        fiat_p256_square(zinv2, zinv);
        fiat_p256_mul(out[k].x, in[k].x, zinv2);
        fiat_p256_mul(zinv2, zinv2, zinv);
        fiat_p256_mul(out[k].y, in[k].y, zinv2);
    }
}

static void cx_p256_table_build(void)
{
    cx_p256_aff base;      /* 16^i * G */
    cx_p256_jac row[16];   /* 1..15 times base, then 16 times base */
    cx_p256_aff aff[16];
    int i, j;
    cx_fe_from_be(base.x, cx_p256_gx);
    cx_fe_from_be(base.y, cx_p256_gy);
    for (i = 0; i < 64; i++) {
        cx_fe_copy(row[0].x, base.x);
        cx_fe_copy(row[0].y, base.y);
        fiat_p256_set_one(row[0].z);
        cx_p256_dbl(&row[1], &row[0]);
        for (j = 2; j < 15; j++) {
            cx_p256_madd(&row[j], &row[j - 1], &base);
        }
        cx_p256_dbl(&row[15], &row[7]);   /* 16 * base */
        cx_p256_row_to_affine(aff, row, 16);
        memcpy(cx_p256_table[i], aff, 15 * sizeof(cx_p256_aff));
        base = aff[15];
    }
}

static void cx_p256_table_ready(void)
{
    int expected = 0;
    if (__atomic_load_n(&cx_p256_table_state, __ATOMIC_ACQUIRE) == 2) {
        return;
    }
    if (__atomic_compare_exchange_n(&cx_p256_table_state, &expected, 1, 0,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        cx_p256_table_build();
        __atomic_store_n(&cx_p256_table_state, 2, __ATOMIC_RELEASE);
        return;
    }
    while (__atomic_load_n(&cx_p256_table_state, __ATOMIC_ACQUIRE) != 2) {
        /* another thread builds it: about a millisecond, once per process */
    }
}

/* ---- k*G ------------------------------------------------------------------- */

/* k (32 bytes big-endian) below n? constant time is not needed: the caller's
 * k is already in range; this guards the exported entry only */
static int cx_p256_scalar_in_range(const unsigned char k[32])
{
    static const unsigned char n_be[32] = {
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51
    };
    unsigned char acc = 0;
    int i;
    for (i = 0; i < 32; i++) {
        acc |= k[i];
    }
    if (acc == 0) {
        return 0;
    }
    return memcmp(k, n_be, 32) < 0;
}

int cx_p256_fiat_mul_base(unsigned char x[32], unsigned char y[32],
                          const unsigned char k[32])
{
    cx_p256_jac acc, sum;
    cx_p256_aff sel;
    cx_fe one, zinv, zinv2;
    int i, j;
    if (!cx_p256_scalar_in_range(k)) {
        return -1;
    }
    cx_p256_table_ready();
    fiat_p256_set_one(one);
    memset(&acc, 0, sizeof(acc));            /* z = 0: the point at infinity */
    for (i = 0; i < 64; i++) {
        /* window i: bits 4i..4i+3 of k, i.e. the nibble of byte 31 - i/2 */
        uint64_t d = (uint64_t) ((k[31 - (i >> 1)] >> ((i & 1) * 4)) & 0x0f);
        uint64_t d_nonzero = ((d | (0 - d)) >> 63);
        uint64_t acc_inf;
        memset(&sel, 0, sizeof(sel));
        for (j = 1; j <= 15; j++) {
            uint64_t eq = ((d ^ (uint64_t) j) - 1) >> 63;
            cx_fe_cmov(sel.x, eq, cx_p256_table[i][j - 1].x);
            cx_fe_cmov(sel.y, eq, cx_p256_table[i][j - 1].y);
        }
        cx_p256_madd(&sum, &acc, &sel);
        acc_inf = cx_fe_is_zero(acc.z);
        cx_fe_cmov(sum.x, acc_inf, sel.x);
        cx_fe_cmov(sum.y, acc_inf, sel.y);
        cx_fe_cmov(sum.z, acc_inf, one);
        cx_fe_cmov(acc.x, d_nonzero, sum.x);
        cx_fe_cmov(acc.y, d_nonzero, sum.y);
        cx_fe_cmov(acc.z, d_nonzero, sum.z);
    }
    cx_fe_inv(zinv, acc.z);
    fiat_p256_square(zinv2, zinv);
    fiat_p256_mul(sum.x, acc.x, zinv2);
    cx_fe_to_be(x, sum.x);
    if (y != NULL) {
        fiat_p256_mul(zinv2, zinv2, zinv);
        fiat_p256_mul(sum.y, acc.y, zinv2);
        cx_fe_to_be(y, sum.y);
    }
    mbedtls_platform_zeroize(&acc, sizeof(acc));
    mbedtls_platform_zeroize(&sum, sizeof(sum));
    mbedtls_platform_zeroize(&sel, sizeof(sel));
    return 0;
}

/* ---- s = k^-1 (e + r d) mod n ------------------------------------------- */

static void cx_sc_from_be(uint64_t out[4], const unsigned char b[32])
{
    uint8_t le[32];
    uint64_t t[4];
    int i;
    for (i = 0; i < 32; i++) {
        le[i] = b[31 - i];
    }
    fiat_p256_scalar_from_bytes(t, le);
    fiat_p256_scalar_to_montgomery(out, t);
    mbedtls_platform_zeroize(le, sizeof(le));
    mbedtls_platform_zeroize(t, sizeof(t));
}

void cx_p256_fiat_sign_s(unsigned char s[32], const unsigned char k[32],
                         const unsigned char r[32], const unsigned char d[32],
                         const unsigned char e[32])
{
    uint64_t km[4], rm[4], dm[4], em[4], kinv[4], t[4], pw[16][4];
    uint8_t le[32];
    int i;
    cx_sc_from_be(km, k);
    cx_sc_from_be(rm, r);
    cx_sc_from_be(dm, d);
    cx_sc_from_be(em, e);
    /* kinv = k^(n-2): a fixed 4-bit window over the public exponent, 252
     * squarings and at most 78 multiplications (square-and-multiply took
     * ~160) */
    fiat_p256_scalar_set_one(pw[0]);
    for (i = 1; i < 16; i++) {
        fiat_p256_scalar_mul(pw[i], pw[i - 1], km);
    }
    fiat_p256_scalar_set_one(kinv);
    for (i = 63; i >= 0; i--) {
        int nib = (int) ((cx_n_minus_2[i >> 4] >> ((i & 15) * 4)) & 0x0f);
        if (i != 63) {
            fiat_p256_scalar_square(kinv, kinv);
            fiat_p256_scalar_square(kinv, kinv);
            fiat_p256_scalar_square(kinv, kinv);
            fiat_p256_scalar_square(kinv, kinv);
        }
        if (nib != 0) {
            fiat_p256_scalar_mul(kinv, kinv, pw[nib]);
        }
    }
    fiat_p256_scalar_mul(t, rm, dm);
    fiat_p256_scalar_add(t, t, em);
    fiat_p256_scalar_mul(t, t, kinv);
    fiat_p256_scalar_from_montgomery(t, t);
    fiat_p256_scalar_to_bytes(le, t);
    for (i = 0; i < 32; i++) {
        s[i] = le[31 - i];
    }
    mbedtls_platform_zeroize(km, sizeof(km));
    mbedtls_platform_zeroize(dm, sizeof(dm));
    mbedtls_platform_zeroize(kinv, sizeof(kinv));
    mbedtls_platform_zeroize(pw, sizeof(pw));
    mbedtls_platform_zeroize(t, sizeof(t));
    mbedtls_platform_zeroize(le, sizeof(le));
}

#endif /* CX_P256_FIAT */
