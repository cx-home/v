// cx-home/v#39: the PSA X25519 path (psa_crypto_ecp.c, cx_psa_x25519) against
// RFC 7748 section 6.1's vectors, its zero-point refusal, and its speed against
// mbedtls's generic Montgomery ladder (mbedtls_ecp_mul on Curve25519) measured
// interleaved in the same process.
#include <psa/crypto.h>
#include <mbedtls/ecp.h>
#include <string.h>
#include <time.h>

static int cx_x25519_unhex(const char *h, uint8_t *out) {
	for (int i = 0; i < 32; i++) {
		unsigned v = 0;
		for (int j = 0; j < 2; j++) {
			char c = h[2 * i + j];
			v = v * 16 + (unsigned)(c <= '9' ? c - '0' : c - 'a' + 10);
		}
		out[i] = (uint8_t)v;
	}
	return 0;
}

static psa_key_id_t cx_x25519_import(const uint8_t *priv) {
	psa_key_attributes_t a = psa_key_attributes_init();
	psa_set_key_type(&a, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_MONTGOMERY));
	psa_set_key_bits(&a, 255);
	psa_set_key_usage_flags(&a, PSA_KEY_USAGE_DERIVE | PSA_KEY_USAGE_EXPORT);
	psa_set_key_algorithm(&a, PSA_ALG_ECDH);
	psa_key_id_t id = 0;
	if (psa_import_key(&a, priv, 32, &id) != PSA_SUCCESS) {
		return 0;
	}
	return id;
}

// 0 = every vector agrees; else the failing step
static int cx_x25519_vectors(void) {
	uint8_t apriv[32], apub[32], bpriv[32], bpub[32], shared[32], out[32];
	size_t n = 0;
	cx_x25519_unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a", apriv);
	cx_x25519_unhex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", apub);
	cx_x25519_unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb", bpriv);
	cx_x25519_unhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", bpub);
	cx_x25519_unhex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", shared);
	if (psa_crypto_init() != PSA_SUCCESS) return 1;
	psa_key_id_t a = cx_x25519_import(apriv);
	psa_key_id_t b = cx_x25519_import(bpriv);
	if (a == 0 || b == 0) return 2;
	if (psa_export_public_key(a, out, 32, &n) != PSA_SUCCESS || n != 32 || memcmp(out, apub, 32) != 0) return 3;
	if (psa_export_public_key(b, out, 32, &n) != PSA_SUCCESS || n != 32 || memcmp(out, bpub, 32) != 0) return 4;
	if (psa_raw_key_agreement(PSA_ALG_ECDH, a, bpub, 32, out, 32, &n) != PSA_SUCCESS || n != 32 || memcmp(out, shared, 32) != 0) return 5;
	if (psa_raw_key_agreement(PSA_ALG_ECDH, b, apub, 32, out, 32, &n) != PSA_SUCCESS || n != 32 || memcmp(out, shared, 32) != 0) return 6;
	// a small-order peer point (u = 0) gives the all-zero secret: refused
	uint8_t zero[32] = {0};
	if (psa_raw_key_agreement(PSA_ALG_ECDH, a, zero, 32, out, 32, &n) == PSA_SUCCESS) return 7;
	psa_destroy_key(a);
	psa_destroy_key(b);
	return 0;
}

static int cx_x25519_rng(void *p, unsigned char *buf, size_t len) {
	(void)p;
	for (size_t i = 0; i < len; i++) buf[i] = (unsigned char)(i * 37 + 11);
	return 0;
}

static double cx_x25519_now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// the PSA agreement's time over the generic ladder's for `rounds` x `per`
// interleaved operations (the least of the rounds for each); <0 on failure
static double cx_x25519_speed_ratio(int rounds, int per, double *psa_us, double *ladder_us) {
	uint8_t apriv[32], bpub[32], out[32];
	size_t n = 0;
	cx_x25519_unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a", apriv);
	cx_x25519_unhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", bpub);
	if (psa_crypto_init() != PSA_SUCCESS) return -1;
	psa_key_id_t a = cx_x25519_import(apriv);
	if (a == 0) return -2;
	mbedtls_ecp_group grp;
	mbedtls_ecp_point R;
	mbedtls_mpi d;
	mbedtls_ecp_group_init(&grp);
	mbedtls_ecp_point_init(&R);
	mbedtls_mpi_init(&d);
	if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519) != 0) return -3;
	if (mbedtls_mpi_read_binary_le(&d, apriv, 32) != 0) return -4;
	mbedtls_mpi_set_bit(&d, 0, 0); mbedtls_mpi_set_bit(&d, 1, 0); mbedtls_mpi_set_bit(&d, 2, 0);
	mbedtls_mpi_set_bit(&d, 254, 1); mbedtls_mpi_set_bit(&d, 255, 0);
	double best_p = 1e9, best_l = 1e9;
	for (int r = 0; r < rounds; r++) {
		double t0 = cx_x25519_now();
		for (int i = 0; i < per; i++) {
			if (psa_raw_key_agreement(PSA_ALG_ECDH, a, bpub, 32, out, 32, &n) != PSA_SUCCESS) return -5;
		}
		double t1 = cx_x25519_now();
		for (int i = 0; i < per; i++) {
			if (mbedtls_ecp_mul(&grp, &R, &d, &grp.G, cx_x25519_rng, NULL) != 0) return -6;
		}
		double t2 = cx_x25519_now();
		if (t1 - t0 < best_p) best_p = t1 - t0;
		if (t2 - t1 < best_l) best_l = t2 - t1;
	}
	*psa_us = best_p * 1e6 / per;
	*ladder_us = best_l * 1e6 / per;
	mbedtls_ecp_group_free(&grp);
	mbedtls_ecp_point_free(&R);
	mbedtls_mpi_free(&d);
	psa_destroy_key(a);
	return best_p / best_l;
}
