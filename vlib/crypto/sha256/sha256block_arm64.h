// SHA-256 block step on the ARMv8 cryptography extension (SHA256H, SHA256H2,
// SHA256SU0, SHA256SU1). Compiled only where the compiler advertises the
// extension (__ARM_FEATURE_SHA2: every Apple silicon target, and an aarch64
// build with +crypto/+sha2); everywhere else the function answers 0 and the
// caller runs block_generic. The digest is byte-identical to block_generic's.
#ifndef V_SHA256_BLOCK_ARM64_H
#define V_SHA256_BLOCK_ARM64_H
#include <stdint.h>
#include <stddef.h>
#if defined(__aarch64__) && defined(__ARM_FEATURE_SHA2) && (defined(__clang__) || defined(__GNUC__))
#include <arm_neon.h>
static const uint32_t v_sha256_arm64_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};
// Four rounds on the message words m (W[4i .. 4i+3]) and the constants k.
#define V_SHA256_ARM64_R4(m, k) \
	do { \
		const uint32x4_t v_wk = vaddq_u32((m), (k)); \
		const uint32x4_t v_a = abcd; \
		abcd = vsha256hq_u32(abcd, efgh, v_wk); \
		efgh = vsha256h2q_u32(efgh, v_a, v_wk); \
	} while (0)
// W[t+16 .. t+19] from W[t ..] (m0), W[t+4 ..], W[t+8 ..], W[t+12 ..], in place in m0.
#define V_SHA256_ARM64_SU(m0, m1, m2, m3) (m0) = vsha256su1q_u32(vsha256su0q_u32((m0), (m1)), (m2), (m3))
// The step is written out round group by round group, with the message words in four named
// vectors and the 64 constants loaded into sixteen vectors once per call: a rolled loop over
// m[i & 3] kept the message schedule on the stack (a load and a store around every
// SHA256SU0/SU1 pair) and ran bulk input 1.25x slower than OpenSSL (cx-home/v#21).
static int v_sha256_block_arm64(uint32_t *state, const uint8_t *data, size_t nblocks) {
	uint32x4_t abcd = vld1q_u32(state);
	uint32x4_t efgh = vld1q_u32(state + 4);
	const uint32_t *kp = v_sha256_arm64_k;
	const uint32x4_t k0 = vld1q_u32(kp + 0), k1 = vld1q_u32(kp + 4), k2 = vld1q_u32(kp + 8),
		k3 = vld1q_u32(kp + 12), k4 = vld1q_u32(kp + 16), k5 = vld1q_u32(kp + 20),
		k6 = vld1q_u32(kp + 24), k7 = vld1q_u32(kp + 28), k8 = vld1q_u32(kp + 32),
		k9 = vld1q_u32(kp + 36), k10 = vld1q_u32(kp + 40), k11 = vld1q_u32(kp + 44),
		k12 = vld1q_u32(kp + 48), k13 = vld1q_u32(kp + 52), k14 = vld1q_u32(kp + 56),
		k15 = vld1q_u32(kp + 60);
	while (nblocks--) {
		const uint32x4_t abcd0 = abcd;
		const uint32x4_t efgh0 = efgh;
		uint32x4_t m0 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data)));
		uint32x4_t m1 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 16)));
		uint32x4_t m2 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 32)));
		uint32x4_t m3 = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 48)));
		V_SHA256_ARM64_R4(m0, k0);
		V_SHA256_ARM64_SU(m0, m1, m2, m3);
		V_SHA256_ARM64_R4(m1, k1);
		V_SHA256_ARM64_SU(m1, m2, m3, m0);
		V_SHA256_ARM64_R4(m2, k2);
		V_SHA256_ARM64_SU(m2, m3, m0, m1);
		V_SHA256_ARM64_R4(m3, k3);
		V_SHA256_ARM64_SU(m3, m0, m1, m2);
		V_SHA256_ARM64_R4(m0, k4);
		V_SHA256_ARM64_SU(m0, m1, m2, m3);
		V_SHA256_ARM64_R4(m1, k5);
		V_SHA256_ARM64_SU(m1, m2, m3, m0);
		V_SHA256_ARM64_R4(m2, k6);
		V_SHA256_ARM64_SU(m2, m3, m0, m1);
		V_SHA256_ARM64_R4(m3, k7);
		V_SHA256_ARM64_SU(m3, m0, m1, m2);
		V_SHA256_ARM64_R4(m0, k8);
		V_SHA256_ARM64_SU(m0, m1, m2, m3);
		V_SHA256_ARM64_R4(m1, k9);
		V_SHA256_ARM64_SU(m1, m2, m3, m0);
		V_SHA256_ARM64_R4(m2, k10);
		V_SHA256_ARM64_SU(m2, m3, m0, m1);
		V_SHA256_ARM64_R4(m3, k11);
		V_SHA256_ARM64_SU(m3, m0, m1, m2);
		V_SHA256_ARM64_R4(m0, k12);
		V_SHA256_ARM64_R4(m1, k13);
		V_SHA256_ARM64_R4(m2, k14);
		V_SHA256_ARM64_R4(m3, k15);
		abcd = vaddq_u32(abcd, abcd0);
		efgh = vaddq_u32(efgh, efgh0);
		data += 64;
	}
	vst1q_u32(state, abcd);
	vst1q_u32(state + 4, efgh);
	return 1;
}
#undef V_SHA256_ARM64_R4
#undef V_SHA256_ARM64_SU
#else
static int v_sha256_block_arm64(uint32_t *state, const uint8_t *data, size_t nblocks) {
	(void)state;
	(void)data;
	(void)nblocks;
	return 0;
}
#endif
#endif
