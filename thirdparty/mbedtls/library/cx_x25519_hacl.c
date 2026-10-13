/*
 * cx-home/v#39: HACL* Curve25519 (3rdparty/everest: formally verified,
 * constant-time) as the X25519 of the PSA builtin ECDH and public-key export
 * (psa_crypto_ecp.c, cx_psa_x25519). mbedtls 3.6 runs TLS 1.3's X25519 key
 * share through PSA, whose builtin is the generic Montgomery ladder over
 * mbedtls_mpi (ecp_mul_mxz): 75 % of a server handshake's CPU. The Everest
 * code was already in the tree and linked (Hacl_Curve25519_joined.o), but it
 * only compiles under MBEDTLS_ECDH_VARIANT_EVEREST_ENABLED, which also
 * reshapes the legacy ECDH context and does not reach TLS 1.3 at all; this
 * unit compiles the same verified code on its own, the way the joined file
 * does, with nothing else changed.
 */
#ifndef _BSD_SOURCE
#define _BSD_SOURCE
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif

#include "common.h"

#if !defined(MBEDTLS_ECDH_VARIANT_EVEREST_ENABLED)

#if defined(__SIZEOF_INT128__) && (__SIZEOF_INT128__ == 16)
#define MBEDTLS_HAVE_INT128
#endif

#if defined(MBEDTLS_HAVE_INT128)
#include "../3rdparty/everest/library/Hacl_Curve25519.c"
#else
#define KRML_VERIFIED_UINT128
#include "../3rdparty/everest/library/kremlib/FStar_UInt128_extracted.c"
#include "../3rdparty/everest/library/legacy/Hacl_Curve25519.c"
#endif

#include "../3rdparty/everest/library/kremlib/FStar_UInt64_FStar_UInt32_FStar_UInt16_FStar_UInt8.c"

#endif /* !MBEDTLS_ECDH_VARIANT_EVEREST_ENABLED */
