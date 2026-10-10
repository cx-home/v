module sha256

// The ARMv8 SHA-256 instructions, where the C compiler has them
// (sha256block_arm64.h); block() falls back to block_generic elsewhere.
#include "@VEXEROOT/vlib/crypto/sha256/sha256block_arm64.h"

fn C.v_sha256_block_arm64(state &u32, data &u8, nblocks usize) int
