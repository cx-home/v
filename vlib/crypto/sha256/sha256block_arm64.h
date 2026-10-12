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
static const uint32_t v_sha256_arm64_k[64] __attribute__((aligned(16))) = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};
// The step is inline assembly, not intrinsics. Each four-round group runs in place on fixed
// registers: v18 = ABCD, v19 = EFGH, v20 = the copy of ABCD that SHA256H2 reads, v4 = W + K.
// The same rounds in arm_neon.h intrinsics compile (clang -O3) to a different register pattern
// (SHA256H writes a fresh copy of ABCD each group) that runs 1.18x slower on Apple silicon:
// 64 MiB x 4 in 115 ms against 97 ms here and 98 ms in the system's CommonCrypto (corecrypto),
// identical state (cx-home/v#21). The constants reload from v_sha256_arm64_k every four groups.
static int v_sha256_block_arm64(uint32_t *state, const uint8_t *data, size_t nblocks) {
	if (nblocks == 0) {
		return 1;
	}
	const uint32_t *k = v_sha256_arm64_k;
	__asm__ volatile(
		"ld1 {v16.4s, v17.4s}, [%[st]]\n"
		"1:\n"
		"ld1 {v0.16b, v1.16b, v2.16b, v3.16b}, [%[d]], #64\n"
		"mov x9, %[k]\n"
		"rev32 v0.16b, v0.16b\n"
		"rev32 v1.16b, v1.16b\n"
		"rev32 v2.16b, v2.16b\n"
		"rev32 v3.16b, v3.16b\n"
		"mov v18.16b, v16.16b\n"
		"mov v19.16b, v17.16b\n"
		"ld1 {v21.4s, v22.4s, v23.4s, v24.4s}, [x9], #64\n"
		"add v4.4s, v0.4s, v21.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v0.4s, v1.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v0.4s, v2.4s, v3.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v1.4s, v22.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v1.4s, v2.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v1.4s, v3.4s, v0.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v2.4s, v23.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v2.4s, v3.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v2.4s, v0.4s, v1.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v3.4s, v24.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v3.4s, v0.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v3.4s, v1.4s, v2.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"ld1 {v21.4s, v22.4s, v23.4s, v24.4s}, [x9], #64\n"
		"add v4.4s, v0.4s, v21.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v0.4s, v1.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v0.4s, v2.4s, v3.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v1.4s, v22.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v1.4s, v2.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v1.4s, v3.4s, v0.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v2.4s, v23.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v2.4s, v3.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v2.4s, v0.4s, v1.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v3.4s, v24.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v3.4s, v0.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v3.4s, v1.4s, v2.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"ld1 {v21.4s, v22.4s, v23.4s, v24.4s}, [x9], #64\n"
		"add v4.4s, v0.4s, v21.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v0.4s, v1.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v0.4s, v2.4s, v3.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v1.4s, v22.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v1.4s, v2.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v1.4s, v3.4s, v0.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v2.4s, v23.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v2.4s, v3.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v2.4s, v0.4s, v1.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v3.4s, v24.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256su0 v3.4s, v0.4s\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256su1 v3.4s, v1.4s, v2.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"ld1 {v21.4s, v22.4s, v23.4s, v24.4s}, [x9], #64\n"
		"add v4.4s, v0.4s, v21.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v1.4s, v22.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v2.4s, v23.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v4.4s, v3.4s, v24.4s\n"
		"mov v20.16b, v18.16b\n"
		"sha256h q18, q19, v4.4s\n"
		"sha256h2 q19, q20, v4.4s\n"
		"add v16.4s, v16.4s, v18.4s\n"
		"add v17.4s, v17.4s, v19.4s\n"
		"subs %[n], %[n], #1\n"
		"b.ne 1b\n"
		"st1 {v16.4s, v17.4s}, [%[st]]\n"
		: [d] "+r"(data), [n] "+r"(nblocks)
		: [st] "r"(state), [k] "r"(k)
		: "x9", "v0", "v1", "v2", "v3", "v4", "v16", "v17", "v18", "v19", "v20", "v21", "v22",
		  "v23", "v24", "memory", "cc");
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
