# thirdparty/libssh2 — the SSH client library behind vlib/net/ssh2

libssh2 **1.11.1**, BSD-3-Clause (`COPYING`), taken from
`https://www.libssh2.org/download/libssh2-1.11.1.tar.gz`
(sha256 `d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7`).

What is here, and nothing else: `include/` verbatim, the `src/` files the upstream
`src/Makefile.inc` lists (`CSOURCES`, `HHEADERS`) plus the three files other sources
`#include` — `mbedtls.c` (through `crypto.c`), `blowfish.c` (through `bcrypt_pbkdf.c`)
and `agent_win.c` (through `agent.c`, empty off Windows) — and one
hand-written `src/libssh2_config.h` selecting the **mbedTLS** backend — the fork's
own `thirdparty/mbedtls`, so the build carries one crypto stack. The other backends
(OpenSSL, libgcrypt, WinCNG, OS/400) are not vendored.

`vlib/net/ssh2` compiles these sources through `#flag` and is the only V module
that names a libssh2 symbol. To move the version: replace `include/` and the listed
`src/` files from the new tarball, keep `src/libssh2_config.h`, record the new
tarball hash here, and record the commit in the downstream register that lists
this tree's patches.
