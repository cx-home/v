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
static int v_sha256_block_arm64(uint32_t *state, const uint8_t *data, size_t nblocks) {
	uint32x4_t abcd = vld1q_u32(state);
	uint32x4_t efgh = vld1q_u32(state + 4);
	while (nblocks--) {
		const uint32x4_t abcd0 = abcd;
		const uint32x4_t efgh0 = efgh;
		uint32x4_t m[4];
		m[0] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data)));
		m[1] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 16)));
		m[2] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 32)));
		m[3] = vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(data + 48)));
		for (int i = 0; i < 16; i++) {
			const uint32x4_t wk = vaddq_u32(m[i & 3], vld1q_u32(v_sha256_arm64_k + 4 * i));
			const uint32x4_t a = abcd;
			abcd = vsha256hq_u32(abcd, efgh, wk);
			efgh = vsha256h2q_u32(efgh, a, wk);
			if (i < 12) {
				// W[4i+16 .. 4i+19] from W[4i ..], W[4i+4 ..], W[4i+8 ..], W[4i+12 ..]
				m[i & 3] = vsha256su1q_u32(vsha256su0q_u32(m[i & 3], m[(i + 1) & 3]),
					m[(i + 2) & 3], m[(i + 3) & 3]);
			}
		}
		abcd = vaddq_u32(abcd, abcd0);
		efgh = vaddq_u32(efgh, efgh0);
		data += 64;
	}
	vst1q_u32(state, abcd);
	vst1q_u32(state + 4, efgh);
	return 1;
}
#else
static int v_sha256_block_arm64(uint32_t *state, const uint8_t *data, size_t nblocks) {
	(void)state;
	(void)data;
	(void)nblocks;
	return 0;
}
#endif
#endif
