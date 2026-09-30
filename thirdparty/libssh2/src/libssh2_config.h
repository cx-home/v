/* libssh2_config.h — the hand-written configuration the V fork builds libssh2
 * with. No configure step runs: V compiles
 * each src/<name>.c into src/<name>.o through `#flag` in vlib/net/ssh2, so this
 * header is the whole of what autotools or CMake would have detected.
 *
 * The crypto backend is mbedTLS — the fork's own thirdparty/mbedtls, the one
 * crypto stack in the build. LIBSSH2_MBEDTLS is defined here rather than on the
 * command line so that no build of these sources can pick a second backend.
 * No zlib: compression is not negotiated (the SFTP payload is octets and the
 * file surface forbids a mode that rewrites them).
 *
 * POSIX targets only (macOS, Linux). The module that uses it is excluded from
 * the wasm32 build by file suffix, and Windows is not a target of this module.
 */
#ifndef CX_LIBSSH2_CONFIG_H
#define CX_LIBSSH2_CONFIG_H

#define LIBSSH2_MBEDTLS 1
#define LIBSSH2_NO_ZLIB 1

#define HAVE_UNISTD_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_UN_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_FCNTL_H 1
#define HAVE_ERRNO_H 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_STRTOLL 1
#define HAVE_SNPRINTF 1
#define HAVE_POLL 1
#define HAVE_SELECT 1
#define HAVE_O_NONBLOCK 1

#endif /* CX_LIBSSH2_CONFIG_H */
