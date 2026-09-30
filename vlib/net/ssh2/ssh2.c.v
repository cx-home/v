// net.ssh2 — the SSH client and its SFTP v3 subsystem, over libssh2 with the
// bundled thirdparty/mbedtls as the crypto backend.
//
// This module is the ONLY V code that names a libssh2 symbol. It is a thin
// binding: a session over an ALREADY-CONNECTED socket descriptor (the caller
// dials, so the caller's own address policy applies to the socket), the host
// key as the peer presented it, the two authentication methods, and the SFTP
// operations. Every failure is an `Ssh2Error` carrying libssh2's own code and,
// for an SFTP operation, the subsystem's status — the caller classifies; this
// module decides nothing.
//
// POSIX targets only. The wasm32 build never imports it (its one importer is a
// `_notd_wasm32_emcc.v` file), so the wasm linker sees no libssh2 symbol.
module ssh2

import net.mbedtls
import crypto.rand
import encoding.base64

#flag -I @VEXEROOT/thirdparty/libssh2/include
#flag -I @VEXEROOT/thirdparty/libssh2/src
// The mbedTLS headers, spelled through `./` on purpose: V keeps ONE copy of an
// identical flag and assigns it to the first module that declared it
// (net.mbedtls), and a third-party object is compiled with its OWN module's
// flags only — so the plain spelling would leave libssh2's objects without the
// backend's headers.
#flag -I @VEXEROOT/thirdparty/./mbedtls/include
#flag -DHAVE_CONFIG_H
#flag -DLIBSSH2_MBEDTLS

#flag @VEXEROOT/thirdparty/libssh2/src/agent.o
#flag @VEXEROOT/thirdparty/libssh2/src/bcrypt_pbkdf.o
#flag @VEXEROOT/thirdparty/libssh2/src/channel.o
#flag @VEXEROOT/thirdparty/libssh2/src/comp.o
#flag @VEXEROOT/thirdparty/libssh2/src/chacha.o
#flag @VEXEROOT/thirdparty/libssh2/src/cipher-chachapoly.o
#flag @VEXEROOT/thirdparty/libssh2/src/crypt.o
#flag @VEXEROOT/thirdparty/libssh2/src/crypto.o
#flag @VEXEROOT/thirdparty/libssh2/src/global.o
#flag @VEXEROOT/thirdparty/libssh2/src/hostkey.o
#flag @VEXEROOT/thirdparty/libssh2/src/keepalive.o
#flag @VEXEROOT/thirdparty/libssh2/src/kex.o
#flag @VEXEROOT/thirdparty/libssh2/src/knownhost.o
#flag @VEXEROOT/thirdparty/libssh2/src/mac.o
#flag @VEXEROOT/thirdparty/libssh2/src/misc.o
#flag @VEXEROOT/thirdparty/libssh2/src/packet.o
#flag @VEXEROOT/thirdparty/libssh2/src/pem.o
#flag @VEXEROOT/thirdparty/libssh2/src/poly1305.o
#flag @VEXEROOT/thirdparty/libssh2/src/publickey.o
#flag @VEXEROOT/thirdparty/libssh2/src/scp.o
#flag @VEXEROOT/thirdparty/libssh2/src/session.o
#flag @VEXEROOT/thirdparty/libssh2/src/sftp.o
#flag @VEXEROOT/thirdparty/libssh2/src/transport.o
#flag @VEXEROOT/thirdparty/libssh2/src/userauth.o
#flag @VEXEROOT/thirdparty/libssh2/src/userauth_kbd_packet.o
#flag @VEXEROOT/thirdparty/libssh2/src/version.o

#include <libssh2.h>
#include <libssh2_sftp.h>

@[typedef]
pub struct C.LIBSSH2_SESSION {}

@[typedef]
pub struct C.LIBSSH2_SFTP {}

@[typedef]
pub struct C.LIBSSH2_SFTP_HANDLE {}

@[typedef]
pub struct C.LIBSSH2_SFTP_ATTRIBUTES {
mut:
	flags       u64
	filesize    u64
	uid         u64
	gid         u64
	permissions u64
	atime       u64
	mtime       u64
}

fn C.libssh2_init(flags int) int
fn C.libssh2_session_init_ex(voidptr, voidptr, voidptr, voidptr) &C.LIBSSH2_SESSION
fn C.libssh2_session_set_blocking(&C.LIBSSH2_SESSION, int)
fn C.libssh2_session_set_timeout(&C.LIBSSH2_SESSION, i64)
fn C.libssh2_session_method_pref(&C.LIBSSH2_SESSION, int, &char) int
fn C.libssh2_session_handshake(&C.LIBSSH2_SESSION, int) int
fn C.libssh2_session_hostkey(&C.LIBSSH2_SESSION, &usize, &int) &char
fn C.libssh2_hostkey_hash(&C.LIBSSH2_SESSION, int) &char
fn C.libssh2_session_last_error(&C.LIBSSH2_SESSION, &&char, &int, int) int
fn C.libssh2_session_disconnect_ex(&C.LIBSSH2_SESSION, int, &char, &char) int
fn C.libssh2_session_free(&C.LIBSSH2_SESSION) int
fn C.libssh2_session_last_errno(&C.LIBSSH2_SESSION) int
fn C.libssh2_userauth_password_ex(&C.LIBSSH2_SESSION, &char, u32, &char, u32, voidptr) int
fn C.libssh2_userauth_publickey_frommemory(&C.LIBSSH2_SESSION, &char, usize, &char, usize, &char, usize, &char) int
fn C.libssh2_sftp_init(&C.LIBSSH2_SESSION) &C.LIBSSH2_SFTP
fn C.libssh2_sftp_shutdown(&C.LIBSSH2_SFTP) int
fn C.libssh2_sftp_last_error(&C.LIBSSH2_SFTP) u64
fn C.libssh2_sftp_open_ex(&C.LIBSSH2_SFTP, &char, u32, u64, i64, int) &C.LIBSSH2_SFTP_HANDLE
fn C.libssh2_sftp_readdir_ex(&C.LIBSSH2_SFTP_HANDLE, &char, usize, &char, usize, &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_read(&C.LIBSSH2_SFTP_HANDLE, &char, usize) isize
fn C.libssh2_sftp_write(&C.LIBSSH2_SFTP_HANDLE, &char, usize) isize
fn C.libssh2_sftp_seek64(&C.LIBSSH2_SFTP_HANDLE, u64)
fn C.libssh2_sftp_close_handle(&C.LIBSSH2_SFTP_HANDLE) int
fn C.libssh2_sftp_stat_ex(&C.LIBSSH2_SFTP, &char, u32, int, &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_rename_ex(&C.LIBSSH2_SFTP, &char, u32, &char, u32, i64) int
fn C.libssh2_sftp_unlink_ex(&C.LIBSSH2_SFTP, &char, u32) int
fn C.libssh2_sftp_rmdir_ex(&C.LIBSSH2_SFTP, &char, u32) int
fn C.libssh2_sftp_mkdir_ex(&C.LIBSSH2_SFTP, &char, u32, i64) int
fn C.libssh2_sftp_symlink_ex(&C.LIBSSH2_SFTP, &char, u32, &char, u32, int) int

// The method classes libssh2_session_method_pref takes.
pub const method_kex = 0
pub const method_hostkey = 1
pub const method_crypt_cs = 2
pub const method_crypt_sc = 3
pub const method_mac_cs = 4
pub const method_mac_sc = 5

// libssh2's own error codes this binding's callers read by name.
pub const error_timeout = -9
pub const error_socket_disconnect = -13
pub const error_authentication_failed = -18
pub const error_publickey_unverified = -19
pub const error_sftp_protocol = -31

// SFTP v3 status codes (draft-ietf-secsh-filexfer-02 §7).
pub const fx_ok = u32(0)
pub const fx_eof = u32(1)
pub const fx_no_such_file = u32(2)
pub const fx_permission_denied = u32(3)
pub const fx_failure = u32(4)
pub const fx_bad_message = u32(5)
pub const fx_no_connection = u32(6)
pub const fx_connection_lost = u32(7)
pub const fx_op_unsupported = u32(8)

// Attribute flags and the file-type bits of `permissions`.
pub const attr_size = u64(0x1)
pub const attr_permissions = u64(0x4)
pub const attr_acmodtime = u64(0x8)
pub const s_ifmt = u64(0o170000)
pub const s_ifdir = u64(0o040000)
pub const s_ifreg = u64(0o100000)
pub const s_iflnk = u64(0o120000)

// Open flags.
pub const fxf_read = u64(0x1)
pub const fxf_write = u64(0x2)
pub const fxf_creat = u64(0x8)
pub const fxf_excl = u64(0x20)

// Ssh2Error — a libssh2 failure. `code` is libssh2's (negative) error code and
// `status` the SFTP subsystem's status when the failure was one
// (`code == error_sftp_protocol`); `detail` is libssh2's own message.
pub struct Ssh2Error {
	Error
pub:
	code   int
	status u32
	detail string
}

pub fn (e Ssh2Error) msg() string {
	if e.code == error_sftp_protocol {
		return 'ssh2: sftp status ${e.status}: ${e.detail}'
	}
	return 'ssh2: error ${e.code}: ${e.detail}'
}

pub fn (e Ssh2Error) code() int {
	return e.code
}

// Attrs — one entry's attributes as the subsystem answered them.
pub struct Attrs {
pub:
	has_size  bool
	size      u64
	has_perm  bool
	perm      u64
	has_mtime bool
	mtime     u64
}

pub fn (a Attrs) is_dir() bool {
	return a.has_perm && (a.perm & s_ifmt) == s_ifdir
}

pub fn (a Attrs) is_regular() bool {
	return a.has_perm && (a.perm & s_ifmt) == s_ifreg
}

pub fn (a Attrs) is_link() bool {
	return a.has_perm && (a.perm & s_ifmt) == s_iflnk
}

fn attrs_of(a C.LIBSSH2_SFTP_ATTRIBUTES) Attrs {
	return Attrs{
		has_size:  (a.flags & attr_size) != 0
		size:      a.filesize
		has_perm:  (a.flags & attr_permissions) != 0
		perm:      a.permissions
		has_mtime: (a.flags & attr_acmodtime) != 0
		mtime:     a.mtime
	}
}

// Entry — one member of a directory read.
pub struct Entry {
pub:
	name  string
	attrs Attrs
}

@[heap]
pub struct Session {
mut:
	ptr  &C.LIBSSH2_SESSION = unsafe { nil }
	sftp &C.LIBSSH2_SFTP    = unsafe { nil }
}

@[heap]
pub struct File {
mut:
	ptr  &C.LIBSSH2_SFTP_HANDLE = unsafe { nil }
	sess &Session               = unsafe { nil }
}

fn init() {
	// libssh2_init seeds the backend's global DRBG from mbedtls' entropy
	// source; it is idempotent and must run before any session exists.
	C.libssh2_init(0)
	_ = mbedtls.new_sslcerts
}

// new_session — a blocking session with a per-operation timeout in
// milliseconds (0 = none). The timeout bounds every blocking read and write
// libssh2 performs, which is what lets a caller put a floor under an
// operation that stops making progress.
pub fn new_session(timeout_ms int) !&Session {
	p := C.libssh2_session_init_ex(unsafe { nil }, unsafe { nil }, unsafe { nil }, unsafe { nil })
	if isnil(p) {
		return Ssh2Error{
			code:   -6
			detail: 'libssh2_session_init failed'
		}
	}
	C.libssh2_session_set_blocking(p, 1)
	C.libssh2_session_set_timeout(p, i64(timeout_ms))
	return &Session{
		ptr: p
	}
}

// set_timeout moves the per-operation timeout of an established session.
pub fn (mut s Session) set_timeout(timeout_ms int) {
	C.libssh2_session_set_timeout(s.ptr, i64(timeout_ms))
}

// prefer restricts the algorithms offered for one method class to the
// comma-separated list `prefs` (before handshake).
pub fn (mut s Session) prefer(method int, prefs string) ! {
	rc := C.libssh2_session_method_pref(s.ptr, method, &char(prefs.str))
	if rc != 0 {
		return s.error_of(rc)
	}
}

fn (s &Session) last_message() string {
	mut msg := &char(unsafe { nil })
	mut n := 0
	C.libssh2_session_last_error(s.ptr, &msg, &n, 0)
	if isnil(msg) || n <= 0 {
		return ''
	}
	return unsafe { tos_clone(&u8(msg)) }
}

fn (s &Session) last_errno() int {
	rc := C.libssh2_session_last_errno(s.ptr)
	return if rc == 0 { error_sftp_protocol } else { rc }
}

fn (s &Session) error_of(rc int) IError {
	mut status := u32(0)
	if rc == error_sftp_protocol && !isnil(s.sftp) {
		status = u32(C.libssh2_sftp_last_error(s.sftp))
	}
	return Ssh2Error{
		code:   rc
		status: status
		detail: s.last_message()
	}
}

// handshake runs the SSH transport's key exchange over the connected socket
// `fd`. It authenticates nothing: the host key it negotiated is readable with
// `host_key` afterwards, and the caller verifies it BEFORE it authenticates.
pub fn (mut s Session) handshake(fd int) ! {
	rc := C.libssh2_session_handshake(s.ptr, fd)
	if rc != 0 {
		return s.error_of(rc)
	}
}

// host_key answers the negotiated host key's algorithm name and its raw
// public-key blob, and sha256 the SHA-256 digest of that blob.
pub fn (s &Session) host_key() !(string, []u8) {
	mut n := usize(0)
	mut typ := 0
	p := C.libssh2_session_hostkey(s.ptr, &n, &typ)
	if isnil(p) || n == 0 {
		return Ssh2Error{
			code:   -14
			detail: 'no host key negotiated'
		}
	}
	blob := unsafe { (&u8(p)).vbytes(int(n)) }.clone()
	alg := match typ {
		1 { 'ssh-rsa' }
		3 { 'ecdsa-sha2-nistp256' }
		4 { 'ecdsa-sha2-nistp384' }
		5 { 'ecdsa-sha2-nistp521' }
		6 { 'ssh-ed25519' }
		else { 'unknown' }
	}

	return alg, blob
}

pub fn (s &Session) host_key_sha256() ![]u8 {
	p := C.libssh2_hostkey_hash(s.ptr, 3)
	if isnil(p) {
		return Ssh2Error{
			code:   -14
			detail: 'no host key hash'
		}
	}
	return unsafe { (&u8(p)).vbytes(32) }.clone()
}

// auth_password — the `password` method (RFC 4252 §8).
pub fn (mut s Session) auth_password(user string, password string) ! {
	rc := C.libssh2_userauth_password_ex(s.ptr, &char(user.str), u32(user.len),
		&char(password.str), u32(password.len), unsafe { nil })
	if rc != 0 {
		return s.error_of(rc)
	}
}

// auth_public_key — the `publickey` method (RFC 4252 §7) with the private
// key given as PEM text in memory, never as a path; `passphrase` may be empty.
// The formats are mbedTLS's: PKCS#1 or PKCS#8 RSA, and SEC1 or PKCS#8 ECDSA
// over P-256, P-384 or P-521. The OpenSSH container format ("BEGIN OPENSSH
// PRIVATE KEY") is not one libssh2's mbedTLS backend reads from memory.
pub fn (mut s Session) auth_public_key(user string, private_pem string, passphrase string) ! {
	// The mbedTLS backend derives the public half from the private key for
	// RSA only; for ECDSA the public key line is handed in beside it.
	public_line := ec_public_line(private_pem, passphrase) or { '' }
	pub_ptr := if public_line == '' { &char(unsafe { nil }) } else { &char(public_line.str) }
	rc := C.libssh2_userauth_publickey_frommemory(s.ptr, &char(user.str), usize(user.len), pub_ptr,
		usize(public_line.len), &char(private_pem.str), usize(private_pem.len),
		&char(passphrase.str))
	if rc != 0 {
		return s.error_of(rc)
	}
}

fn C.mbedtls_pk_get_type(&C.mbedtls_pk_context) int
fn C.mbedtls_pk_ec(C.mbedtls_pk_context) voidptr
fn C.mbedtls_ecp_keypair_get_group_id(voidptr) int
fn C.mbedtls_ecp_write_public_key(voidptr, int, &usize, &u8, usize) int

fn ssh2_rng(_ voidptr, buf &u8, n usize) int {
	b := rand.bytes(int(n)) or { return -1 }
	unsafe { vmemcpy(buf, b.data, int(n)) }
	return 0
}

// ec_public_line — the OpenSSH public key line ("ecdsa-sha2-nistp256
// <base64 blob>") of an ECDSA private key in PEM, or an error for any other
// key type (RSA's public half libssh2 derives itself).
fn ec_public_line(private_pem string, passphrase string) !string {
	mut pk := C.mbedtls_pk_context{}
	C.mbedtls_pk_init(&pk)
	defer {
		C.mbedtls_pk_free(&pk)
	}
	mut pem := private_pem.bytes()
	pem << u8(0)
	if C.mbedtls_pk_parse_key(&pk, pem.data, usize(pem.len), passphrase.str, usize(passphrase.len),
		ssh2_rng, unsafe { nil }) != 0 {
		return error('not a key mbedTLS reads')
	}
	typ := C.mbedtls_pk_get_type(&pk)
	if typ != 2 && typ != 4 {
		return error('not an EC key')
	}
	kp := C.mbedtls_pk_ec(pk)
	curve, bits := match C.mbedtls_ecp_keypair_get_group_id(kp) {
		3 { 'nistp256', 256 }
		4 { 'nistp384', 384 }
		5 { 'nistp521', 521 }
		else { return error('curve') }
	}

	_ = bits
	mut q := []u8{len: 140}
	mut olen := usize(0)
	if C.mbedtls_ecp_write_public_key(kp, 0, &olen, q.data, usize(q.len)) != 0 {
		return error('public point')
	}
	alg := 'ecdsa-sha2-${curve}'
	mut blob := []u8{}
	ssh_string(mut blob, alg.bytes())
	ssh_string(mut blob, curve.bytes())
	ssh_string(mut blob, q[..int(olen)])
	return '${alg} ${base64.encode(blob)}'
}

fn ssh_string(mut out []u8, v []u8) {
	n := u32(v.len)
	out << u8(n >> 24)
	out << u8(n >> 16)
	out << u8(n >> 8)
	out << u8(n)
	out << v
}

// sftp_start starts the SFTP subsystem on the authenticated session.
pub fn (mut s Session) sftp_start() ! {
	p := C.libssh2_sftp_init(s.ptr)
	if isnil(p) {
		return s.error_of(s.last_errno())
	}
	s.sftp = p
}

// close ends the subsystem and the session. Idempotent.
pub fn (mut s Session) close() {
	if !isnil(s.sftp) {
		C.libssh2_sftp_shutdown(s.sftp)
		s.sftp = unsafe { nil }
	}
	if !isnil(s.ptr) {
		C.libssh2_session_disconnect_ex(s.ptr, 11, c'closed', c'')
		C.libssh2_session_free(s.ptr)
		s.ptr = unsafe { nil }
	}
}

pub fn (s &Session) is_open() bool {
	return !isnil(s.ptr)
}

// read_dir answers the members of directory `path` except `.` and `..`, in
// the order the peer sent them, reading no more than `limit` of them (0 = no
// limit); `more` is true when the peer had another one to send. A caller that
// bounds a listing asks for one past its bound and reads the count, so a
// directory of ten million entries costs `limit` reads and not ten million.
pub fn (mut s Session) read_dir(path string, limit int) !([]Entry, bool) {
	h := C.libssh2_sftp_open_ex(s.sftp, &char(path.str), u32(path.len), 0, 0, 1)
	if isnil(h) {
		return s.error_of(s.last_errno())
	}
	mut out := []Entry{}
	mut buf := []u8{len: 1024}
	for {
		mut a := C.LIBSSH2_SFTP_ATTRIBUTES{}
		rc := C.libssh2_sftp_readdir_ex(h, &char(buf.data), usize(buf.len), unsafe { nil }, 0, &a)
		if rc == 0 {
			break
		}
		if rc < 0 {
			e := s.error_of(rc)
			C.libssh2_sftp_close_handle(h)
			return e
		}
		name := unsafe { (&u8(buf.data)).vbytes(rc) }.bytestr()
		if name == '.' || name == '..' {
			continue
		}
		if limit > 0 && out.len >= limit {
			C.libssh2_sftp_close_handle(h)
			return out, true
		}
		out << Entry{
			name:  name
			attrs: attrs_of(a)
		}
	}
	C.libssh2_sftp_close_handle(h)
	return out, false
}

// lstat — the entry at `path` itself, never what a link points at.
pub fn (mut s Session) lstat(path string) !Attrs {
	mut a := C.LIBSSH2_SFTP_ATTRIBUTES{}
	rc := C.libssh2_sftp_stat_ex(s.sftp, &char(path.str), u32(path.len), 1, &a)
	if rc != 0 {
		return s.error_of(rc)
	}
	return attrs_of(a)
}

// read_link answers a link's target as the peer states it.
pub fn (mut s Session) read_link(path string) !string {
	mut buf := []u8{len: 4096}
	rc := C.libssh2_sftp_symlink_ex(s.sftp, &char(path.str), u32(path.len), &char(buf.data),
		u32(buf.len), 1)
	if rc < 0 {
		return s.error_of(rc)
	}
	return unsafe { (&u8(buf.data)).vbytes(rc) }.bytestr()
}

// open_file — `flags` from the fxf_* constants, `mode` the create mode.
pub fn (mut s Session) open_file(path string, flags u64, mode int) !&File {
	h := C.libssh2_sftp_open_ex(s.sftp, &char(path.str), u32(path.len), flags, i64(mode), 0)
	if isnil(h) {
		return s.error_of(s.last_errno())
	}
	return &File{
		ptr:  h
		sess: s
	}
}

pub fn (mut f File) seek(offset u64) {
	C.libssh2_sftp_seek64(f.ptr, offset)
}

// read reads at most buf.len octets; 0 is end of file.
pub fn (mut f File) read(mut buf []u8) !int {
	rc := C.libssh2_sftp_read(f.ptr, &char(buf.data), usize(buf.len))
	if rc < 0 {
		return f.sess.error_of(int(rc))
	}
	return int(rc)
}

// write writes all of `data`.
pub fn (mut f File) write(data []u8) ! {
	mut off := 0
	for off < data.len {
		rc := C.libssh2_sftp_write(f.ptr, unsafe { &char(&data[off]) }, usize(data.len - off))
		if rc < 0 {
			return f.sess.error_of(int(rc))
		}
		off += int(rc)
	}
}

pub fn (mut f File) close() ! {
	if isnil(f.ptr) {
		return
	}
	rc := C.libssh2_sftp_close_handle(f.ptr)
	f.ptr = unsafe { nil }
	if rc != 0 {
		return f.sess.error_of(rc)
	}
}

// rename — never overwrites: `flags` 0 asks the peer to refuse an existing
// target (the file surface's `:exists`).
pub fn (mut s Session) rename(from string, to string) ! {
	rc := C.libssh2_sftp_rename_ex(s.sftp, &char(from.str), u32(from.len), &char(to.str),
		u32(to.len), 0)
	if rc != 0 {
		return s.error_of(rc)
	}
}

pub fn (mut s Session) remove_file(path string) ! {
	rc := C.libssh2_sftp_unlink_ex(s.sftp, &char(path.str), u32(path.len))
	if rc != 0 {
		return s.error_of(rc)
	}
}

pub fn (mut s Session) remove_dir(path string) ! {
	rc := C.libssh2_sftp_rmdir_ex(s.sftp, &char(path.str), u32(path.len))
	if rc != 0 {
		return s.error_of(rc)
	}
}

pub fn (mut s Session) make_dir(path string, mode int) ! {
	rc := C.libssh2_sftp_mkdir_ex(s.sftp, &char(path.str), u32(path.len), i64(mode))
	if rc != 0 {
		return s.error_of(rc)
	}
}
