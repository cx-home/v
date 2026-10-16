// cx-home/v#39: X25519 on fiat-crypto's curve25519 field (library/
// cx_x25519_fiat.c over thirdparty/fiat-25519) against RFC 7748 section 5.2's
// vectors (vector 1, the 1- and 1,000-iteration ladders) and against HACL*
// Curve25519 (the X25519 it replaces where __int128 compiles) on RFC 7748's
// vector 2 and 256 pseudo-random scalar/point pairs.
#include <stdint.h>
#include <string.h>
#include "cx_x25519_fiat.h" // library/ is on the -I path (mbedtls.c.v)

void Hacl_Curve25519_crypto_scalarmult(uint8_t *mypublic, uint8_t *secret, uint8_t *basepoint);

static void cx_xf_unhex(const char *h, uint8_t *out) {
	for (int i = 0; i < 32; i++) {
		unsigned v = 0;
		for (int j = 0; j < 2; j++) {
			char c = h[2 * i + j];
			v = v * 16 + (unsigned)(c <= '9' ? c - '0' : (c | 32) - 'a' + 10);
		}
		out[i] = (uint8_t)v;
	}
}

// 1: the build has no fiat X25519 (tcc, msvc); 0: every case agrees;
// negative: the failing case
static int cx_x25519_fiat_cases(void) {
#if defined(CX_X25519_FIAT)
	uint8_t k[32], u[32], want[32], got[32], ref[32];
	cx_xf_unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4", k);
	cx_xf_unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c", u);
	cx_xf_unhex("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552", want);
	cx_x25519_fiat(got, k, u);
	if (memcmp(got, want, 32) != 0) return -1;
	// vector 2, against HACL*
	cx_xf_unhex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d", k);
	cx_xf_unhex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493", u);
	cx_x25519_fiat(got, k, u);
	Hacl_Curve25519_crypto_scalarmult(ref, k, u);
	if (memcmp(got, ref, 32) != 0) return -2;
	// the iterated ladder: k = u = 9; k, u = X25519(k, u), k
	uint8_t kk[32] = {9}, uu[32] = {9}, r[32];
	for (int i = 1; i <= 1000; i++) {
		cx_x25519_fiat(r, kk, uu);
		memcpy(uu, kk, 32);
		memcpy(kk, r, 32);
		if (i == 1) {
			cx_xf_unhex("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079", want);
			if (memcmp(kk, want, 32) != 0) return -3;
		}
	}
	cx_xf_unhex("684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51", want);
	if (memcmp(kk, want, 32) != 0) return -4;
	// 256 pseudo-random pairs (xorshift64*), fiat == HACL*; the point's top bit
	// is set on half of them (both mask it)
	uint64_t s = 0x9e3779b97f4a7c15ull;
	for (int n = 0; n < 256; n++) {
		for (int i = 0; i < 32; i++) {
			s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
			k[i] = (uint8_t)((s * 0x2545f4914f6cdd1dull) >> 56);
			s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
			u[i] = (uint8_t)((s * 0x2545f4914f6cdd1dull) >> 56);
		}
		if (n & 1) u[31] |= 0x80;
		cx_x25519_fiat(got, k, u);
		memcpy(r, k, 32);
		Hacl_Curve25519_crypto_scalarmult(ref, r, u);
		if (memcmp(got, ref, 32) != 0) return -100 - n;
	}
	return 0;
#else
	return 1;
#endif
}
