// cx-home/v#39: a TLS connection whose handshake waits on the peer does not
// hold full-size record buffers (the cx fork's MBEDTLS_SSL_CX_RELEASE_BUFFERS,
// mbedtls_ssl_cx_release_wait). A client and a server run a TLS 1.3 handshake
// over two in-memory pipes, one step at a time, so the test reads each side's
// record-buffer bytes at the exact points where it waits: the server after
// setup and after it has sent ServerHello..Finished (waiting for the client's
// Finished), the client after its ClientHello. Then 20,000 bytes cross each
// way (records larger than the idle buffers) to show the buffers grow back.
#include <string.h>
#include <psa/crypto.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>

typedef struct {
	unsigned char b[65536];
	size_t r, w;
} cx_hw_pipe;

// one side of the connection: it writes to tx and reads from rx
typedef struct {
	cx_hw_pipe *tx, *rx;
} cx_hw_end;

static int cx_hw_send(void *ctx, const unsigned char *buf, size_t len) {
	cx_hw_pipe *p = ((cx_hw_end *) ctx)->tx;
	size_t room = sizeof(p->b) - p->w;
	if (len > room) len = room;
	if (len == 0) return MBEDTLS_ERR_SSL_WANT_WRITE;
	memcpy(p->b + p->w, buf, len);
	p->w += len;
	return (int) len;
}

static int cx_hw_recv(void *ctx, unsigned char *buf, size_t len) {
	cx_hw_pipe *p = ((cx_hw_end *) ctx)->rx;
	size_t have = p->w - p->r;
	if (have == 0) return MBEDTLS_ERR_SSL_WANT_READ;
	if (len > have) len = have;
	memcpy(buf, p->b + p->r, len);
	p->r += len;
	if (p->r == p->w) p->r = p->w = 0;
	return (int) len;
}

static int cx_hw_bytes(mbedtls_ssl_context *s) {
#if defined(MBEDTLS_SSL_VARIABLE_BUFFER_LENGTH)
	return (int) (s->private_in_buf_len + s->private_out_buf_len);
#else
	(void) s;
	return (int) (MBEDTLS_SSL_IN_CONTENT_LEN + MBEDTLS_SSL_OUT_CONTENT_LEN);
#endif
}

static int cx_hw_xfer(mbedtls_ssl_context *from, mbedtls_ssl_context *to, int n, int seed) {
	static unsigned char msg[20000], got[20000];
	for (int i = 0; i < n; i++) msg[i] = (unsigned char) ((i * 7 + seed) % 251);
	int off = 0, rd = 0;
	for (int spins = 0; spins < 1000 && rd < n; spins++) {
		if (off < n) {
			int r = mbedtls_ssl_write(from, msg + off, (size_t) (n - off));
			if (r > 0) off += r;
			else if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) return -1;
		}
		int r = mbedtls_ssl_read(to, got + rd, (size_t) (n - rd));
		if (r > 0) rd += r;
		else if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) return -2;
	}
	return (rd == n && memcmp(msg, got, (size_t) n) == 0) ? 0 : -3;
}

// out: [0] server bytes after setup, [1] client bytes waiting after its
// ClientHello, [2] server bytes waiting after its flight, [3] server bytes
// once the handshake is over, [4] both 20,000-byte transfers intact (1/0).
static int cx_hw_run(const char *cert_pem, const char *key_pem, int *out) {
	static cx_hw_pipe c2s, s2c;
	cx_hw_end send_srv = {&s2c, &c2s}, send_cli = {&c2s, &s2c};
	mbedtls_entropy_context ent;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_x509_crt crt;
	mbedtls_pk_context key;
	mbedtls_ssl_config sconf, cconf;
	mbedtls_ssl_context srv, cli;
	int rc = 0;
	memset(&c2s, 0, sizeof(c2s));
	memset(&s2c, 0, sizeof(s2c));
	for (int i = 0; i < 5; i++) out[i] = -1;
	if (psa_crypto_init() != PSA_SUCCESS) return 1;
	mbedtls_entropy_init(&ent);
	mbedtls_ctr_drbg_init(&drbg);
	mbedtls_x509_crt_init(&crt);
	mbedtls_pk_init(&key);
	mbedtls_ssl_config_init(&sconf);
	mbedtls_ssl_config_init(&cconf);
	mbedtls_ssl_init(&srv);
	mbedtls_ssl_init(&cli);
	if (mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &ent, NULL, 0) != 0) { rc = 2; goto done; }
	if (mbedtls_x509_crt_parse(&crt, (const unsigned char *) cert_pem, strlen(cert_pem) + 1) != 0) { rc = 3; goto done; }
	if (mbedtls_pk_parse_key(&key, (const unsigned char *) key_pem, strlen(key_pem) + 1, NULL, 0,
	                         mbedtls_ctr_drbg_random, &drbg) != 0) { rc = 4; goto done; }
	if (mbedtls_ssl_config_defaults(&sconf, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0 ||
	    mbedtls_ssl_config_defaults(&cconf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) { rc = 5; goto done; }
	mbedtls_ssl_conf_rng(&sconf, mbedtls_ctr_drbg_random, &drbg);
	mbedtls_ssl_conf_rng(&cconf, mbedtls_ctr_drbg_random, &drbg);
	mbedtls_ssl_conf_min_tls_version(&sconf, MBEDTLS_SSL_VERSION_TLS1_3);
	mbedtls_ssl_conf_min_tls_version(&cconf, MBEDTLS_SSL_VERSION_TLS1_3);
	mbedtls_ssl_conf_authmode(&cconf, MBEDTLS_SSL_VERIFY_NONE);
	if (mbedtls_ssl_conf_own_cert(&sconf, &crt, &key) != 0) { rc = 6; goto done; }
	if (mbedtls_ssl_setup(&srv, &sconf) != 0 || mbedtls_ssl_setup(&cli, &cconf) != 0) { rc = 7; goto done; }
	mbedtls_ssl_set_bio(&srv, &send_srv, cx_hw_send, cx_hw_recv, NULL);
	mbedtls_ssl_set_bio(&cli, &send_cli, cx_hw_send, cx_hw_recv, NULL);
	out[0] = cx_hw_bytes(&srv);
	{
		int cdone = 0, sdone = 0;
		for (int round = 0; round < 32 && !(cdone && sdone); round++) {
			if (!cdone) {
				size_t before = c2s.w;
				int r = mbedtls_ssl_handshake(&cli);
				if (r == 0) cdone = 1;
				else if (r != MBEDTLS_ERR_SSL_WANT_READ) { rc = 8; goto done; }
				else if (out[1] < 0 && c2s.w > before) out[1] = cx_hw_bytes(&cli);
			}
			if (!sdone) {
				size_t before = s2c.w;
				int r = mbedtls_ssl_handshake(&srv);
				if (r == 0) sdone = 1;
				else if (r != MBEDTLS_ERR_SSL_WANT_READ) { rc = 9; goto done; }
				else if (out[2] < 0 && s2c.w > before) out[2] = cx_hw_bytes(&srv);
			}
		}
		if (!(cdone && sdone)) { rc = 10; goto done; }
	}
	out[3] = cx_hw_bytes(&srv);
	out[4] = (cx_hw_xfer(&cli, &srv, 20000, 1) == 0 && cx_hw_xfer(&srv, &cli, 20000, 2) == 0) ? 1 : 0;
done:
	mbedtls_ssl_free(&cli);
	mbedtls_ssl_free(&srv);
	mbedtls_ssl_config_free(&cconf);
	mbedtls_ssl_config_free(&sconf);
	mbedtls_pk_free(&key);
	mbedtls_x509_crt_free(&crt);
	mbedtls_ctr_drbg_free(&drbg);
	mbedtls_entropy_free(&ent);
	return rc;
}
