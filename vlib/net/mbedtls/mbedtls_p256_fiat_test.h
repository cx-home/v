// cx-home/v#39: P-256 ECDSA signing over fiat-crypto (thirdparty/mbedtls/
// library/cx_p256_fiat.c) against mbedtls's own arithmetic: k*G equal to
// mbedtls_ecp_mul's for edge and random scalars, RFC 6979 A.2.5's
// deterministic signatures byte for byte, signatures that mbedtls_ecdsa_verify
// accepts, and the signature's time against the builtin comb's k*G alone.
#include <mbedtls/ecdsa.h>
#include <mbedtls/ecp.h>
#include <mbedtls/sha256.h>
#include <string.h>
#include <time.h>

// the fiat unit exists only where the compiler has a 128-bit integer (not tcc,
// not msvc): there the builtin signs and the k*G comparison has nothing to test
#if defined(__SIZEOF_INT128__) && !defined(__TINYC__) && !defined(CX_P256_FIAT_OFF)
#define CX_P256T_FIAT 1
int cx_p256_fiat_mul_base(unsigned char x[32], unsigned char y[32], const unsigned char k[32]);
#endif

static void cx_p256t_unhex(const char *h, unsigned char *out, int n) {
	for (int i = 0; i < n; i++) {
		unsigned v = 0;
		for (int j = 0; j < 2; j++) {
			char c = h[2 * i + j];
			v = v * 16 + (unsigned)(c <= '9' ? c - '0' : (c >= 'a' ? c - 'a' : c - 'A') + 10);
		}
		out[i] = (unsigned char)v;
	}
}

// a deterministic xorshift byte stream for the random cases
static unsigned long long cx_p256t_state = 0x9e3779b97f4a7c15ULL;
static int cx_p256t_rng(void *p, unsigned char *buf, size_t len) {
	(void)p;
	for (size_t i = 0; i < len; i++) {
		cx_p256t_state ^= cx_p256t_state << 13;
		cx_p256t_state ^= cx_p256t_state >> 7;
		cx_p256t_state ^= cx_p256t_state << 17;
		buf[i] = (unsigned char)(cx_p256t_state >> 32);
	}
	return 0;
}

// 0 = fiat's k*G equals mbedtls_ecp_mul's for every case; else 1000 + the edge
// case or 2000 + the random case that differs
static int cx_p256_mul_base_agrees(int random_cases) {
#if !defined(CX_P256T_FIAT)
	(void)random_cases;
	return 0;
#else
	static const char *edges[] = {
		"0000000000000000000000000000000000000000000000000000000000000001",
		"0000000000000000000000000000000000000000000000000000000000000002",
		"000000000000000000000000000000000000000000000000000000000000000f",
		"0000000000000000000000000000000000000000000000000000000000000010",
		"0000000000000000000000000000000000000000000000000000000000000011",
		"00000000000000000000000000000000000000000000000000000000000000ff",
		"1000000000000000000000000000000000000000000000000000000000000000",
		"f000000000000000000000000000000000000000000000000000000000000000",
		"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
		"ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550",
		"ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc63254f",
		"8000000000000000000000000000000000000000000000000000000000000000",
		0
	};
	mbedtls_ecp_group grp;
	mbedtls_ecp_point R;
	mbedtls_mpi k;
	unsigned char kb[32], fx[32], fy[32], mx[32], my[32];
	int ret = 0;
	mbedtls_ecp_group_init(&grp);
	mbedtls_ecp_point_init(&R);
	mbedtls_mpi_init(&k);
	if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) != 0) return 1;
	for (int i = 0; i < 12 + random_cases; i++) {
		if (i < 12) {
			cx_p256t_unhex(edges[i], kb, 32);
		} else {
			if (mbedtls_ecp_gen_privkey(&grp, &k, cx_p256t_rng, NULL) != 0) { ret = 2; break; }
			mbedtls_mpi_write_binary(&k, kb, 32);
		}
		mbedtls_mpi_read_binary(&k, kb, 32);
		if (mbedtls_ecp_mul(&grp, &R, &k, &grp.G, cx_p256t_rng, NULL) != 0) { ret = 3; break; }
		mbedtls_mpi_write_binary(&R.MBEDTLS_PRIVATE(X), mx, 32);
		mbedtls_mpi_write_binary(&R.MBEDTLS_PRIVATE(Y), my, 32);
		if (cx_p256_fiat_mul_base(fx, fy, kb) != 0 || memcmp(fx, mx, 32) != 0 || memcmp(fy, my, 32) != 0) {
			ret = (i < 12 ? 1000 : 2000) + i;
			break;
		}
	}
	// 0 and n are refused
	if (ret == 0) {
		cx_p256t_unhex("0000000000000000000000000000000000000000000000000000000000000000", kb, 32);
		if (cx_p256_fiat_mul_base(fx, fy, kb) != -1) ret = 4;
		cx_p256t_unhex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", kb, 32);
		if (cx_p256_fiat_mul_base(fx, fy, kb) != -1) ret = 5;
	}
	mbedtls_ecp_group_free(&grp);
	mbedtls_ecp_point_free(&R);
	mbedtls_mpi_free(&k);
	return ret;
#endif
}

// 0 = RFC 6979 A.2.5 (P-256, SHA-256, "sample" and "test") byte for byte
static int cx_p256_rfc6979(void) {
	static const char *msgs[2] = { "sample", "test" };
	static const char *rs[2] = {
		"efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716",
		"f1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367" };
	static const char *ss[2] = {
		"f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8",
		"019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083" };
	mbedtls_ecp_group grp;
	mbedtls_mpi d, r, s;
	unsigned char db[32], h[32], want[32], got[32];
	int ret = 0;
	mbedtls_ecp_group_init(&grp);
	mbedtls_mpi_init(&d); mbedtls_mpi_init(&r); mbedtls_mpi_init(&s);
	if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) != 0) return 1;
	cx_p256t_unhex("c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721", db, 32);
	mbedtls_mpi_read_binary(&d, db, 32);
	for (int i = 0; i < 2 && ret == 0; i++) {
		if (mbedtls_sha256((const unsigned char *)msgs[i], strlen(msgs[i]), h, 0) != 0) { ret = 2; break; }
		if (mbedtls_ecdsa_sign_det_ext(&grp, &r, &s, &d, h, 32, MBEDTLS_MD_SHA256, cx_p256t_rng, NULL) != 0) { ret = 3; break; }
		cx_p256t_unhex(rs[i], want, 32);
		mbedtls_mpi_write_binary(&r, got, 32);
		if (memcmp(want, got, 32) != 0) { ret = 10 + i; break; }
		cx_p256t_unhex(ss[i], want, 32);
		mbedtls_mpi_write_binary(&s, got, 32);
		if (memcmp(want, got, 32) != 0) { ret = 20 + i; break; }
	}
	mbedtls_ecp_group_free(&grp);
	mbedtls_mpi_free(&d); mbedtls_mpi_free(&r); mbedtls_mpi_free(&s);
	return ret;
}

// 0 = `cases` random keys and digests sign (mbedtls_ecdsa_sign) and verify
// (mbedtls_ecdsa_verify), and a flipped digest bit does not verify
static int cx_p256_sign_verify(int cases) {
	mbedtls_ecp_group grp;
	mbedtls_ecp_point Q;
	mbedtls_mpi d, r, s;
	unsigned char h[32];
	int ret = 0;
	mbedtls_ecp_group_init(&grp);
	mbedtls_ecp_point_init(&Q);
	mbedtls_mpi_init(&d); mbedtls_mpi_init(&r); mbedtls_mpi_init(&s);
	if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) != 0) return 1;
	for (int i = 0; i < cases; i++) {
		if (mbedtls_ecp_gen_keypair(&grp, &d, &Q, cx_p256t_rng, NULL) != 0) { ret = 2; break; }
		cx_p256t_rng(NULL, h, 32);
		if (mbedtls_ecdsa_sign(&grp, &r, &s, &d, h, 32, cx_p256t_rng, NULL) != 0) { ret = 3; break; }
		if (mbedtls_ecdsa_verify(&grp, h, 32, &Q, &r, &s) != 0) { ret = 1000 + i; break; }
		h[i % 32] ^= 1;
		if (mbedtls_ecdsa_verify(&grp, h, 32, &Q, &r, &s) == 0) { ret = 2000 + i; break; }
	}
	mbedtls_ecp_group_free(&grp);
	mbedtls_ecp_point_free(&Q);
	mbedtls_mpi_free(&d); mbedtls_mpi_free(&r); mbedtls_mpi_free(&s);
	return ret;
}

static double cx_p256t_now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// a whole signature's time (mbedtls_ecdsa_sign) over the builtin comb's k*G
// alone (mbedtls_ecp_mul, the builtin signature's largest step), `rounds` x
// `per` interleaved, the least of the rounds each; <0 on failure
static double cx_p256_sign_speed_ratio(int rounds, int per, double *sign_us, double *comb_us) {
	mbedtls_ecp_group grp;
	mbedtls_ecp_point Q, R;
	mbedtls_mpi d, r, s;
	unsigned char h[32];
	mbedtls_ecp_group_init(&grp);
	mbedtls_ecp_point_init(&Q); mbedtls_ecp_point_init(&R);
	mbedtls_mpi_init(&d); mbedtls_mpi_init(&r); mbedtls_mpi_init(&s);
	if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) != 0) return -1;
	if (mbedtls_ecp_gen_keypair(&grp, &d, &Q, cx_p256t_rng, NULL) != 0) return -2;
	cx_p256t_rng(NULL, h, 32);
	double best_s = 1e9, best_c = 1e9;
	for (int k = 0; k < rounds; k++) {
		double t0 = cx_p256t_now();
		for (int i = 0; i < per; i++) {
			if (mbedtls_ecdsa_sign(&grp, &r, &s, &d, h, 32, cx_p256t_rng, NULL) != 0) return -3;
		}
		double t1 = cx_p256t_now();
		for (int i = 0; i < per; i++) {
			if (mbedtls_ecp_mul(&grp, &R, &d, &grp.G, cx_p256t_rng, NULL) != 0) return -4;
		}
		double t2 = cx_p256t_now();
		if (t1 - t0 < best_s) best_s = t1 - t0;
		if (t2 - t1 < best_c) best_c = t2 - t1;
	}
	*sign_us = best_s * 1e6 / per;
	*comb_us = best_c * 1e6 / per;
	mbedtls_ecp_group_free(&grp);
	mbedtls_ecp_point_free(&Q); mbedtls_ecp_point_free(&R);
	mbedtls_mpi_free(&d); mbedtls_mpi_free(&r); mbedtls_mpi_free(&s);
	return best_s / best_c;
}
