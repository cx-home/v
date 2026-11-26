// cx-home/cx-platform-store#90: a TLS connection is read by one thread and
// written by another (the store's XSP sx_conn_reader / sx_conn_writer). Each
// direction must touch only its own record buffer: under the cx fork's
// MBEDTLS_SSL_CX_RELEASE_BUFFERS every mbedtls_ssl_read and mbedtls_ssl_write
// ran mbedtls_ssl_cx_release, which resized BOTH buffers (and
// handle_buffer_resizing rewrote both sets of pointers), so the reader freed
// the output buffer the writer was encrypting into and the writer the input
// buffer the reader was decrypting from: ASan heap-use-after-free in
// resize_buffer, glibc 'double free or corruption (!prev)' on the kind pods.
//
// cx_rw_interleave runs the interleaving one step at a time on one thread: the
// writer's entry (mbedtls_ssl_cx_grow_out, as mbedtls_ssl_write starts) then a
// whole mbedtls_ssl_read, and the reader's growth for a large record
// (mbedtls_ssl_cx_grow_in, as ssl_get_next_record does) then a whole
// mbedtls_ssl_write; each time the other direction's buffer must be the same
// allocation, the same length and the same pointers. cx_rw_threads runs the
// real thing: a server read thread and write thread on one context against a
// client pumped by a third thread, records larger than the idle buffers each
// way, every byte checked.
#include <string.h>
#include <pthread.h>
#include <sched.h>
#include <psa/crypto.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>

#if defined(MBEDTLS_SSL_CX_RELEASE_BUFFERS)
void mbedtls_ssl_cx_grow_in(mbedtls_ssl_context *ssl);
void mbedtls_ssl_cx_grow_out(mbedtls_ssl_context *ssl);
#endif

typedef struct {
	pthread_mutex_t mu;
	unsigned char b[65536];
	size_t r, w;
} cx_rw_pipe;

typedef struct {
	cx_rw_pipe *tx, *rx;
} cx_rw_end;

static int cx_rw_send(void *ctx, const unsigned char *buf, size_t len) {
	cx_rw_pipe *p = ((cx_rw_end *) ctx)->tx;
	pthread_mutex_lock(&p->mu);
	if (p->r == p->w) p->r = p->w = 0;
	size_t room = sizeof(p->b) - p->w;
	if (len > room) len = room;
	if (len > 0) {
		memcpy(p->b + p->w, buf, len);
		p->w += len;
	}
	pthread_mutex_unlock(&p->mu);
	return len == 0 ? MBEDTLS_ERR_SSL_WANT_WRITE : (int) len;
}

static int cx_rw_recv(void *ctx, unsigned char *buf, size_t len) {
	cx_rw_pipe *p = ((cx_rw_end *) ctx)->rx;
	pthread_mutex_lock(&p->mu);
	size_t have = p->w - p->r;
	if (len > have) len = have;
	if (len > 0) {
		memcpy(buf, p->b + p->r, len);
		p->r += len;
	}
	pthread_mutex_unlock(&p->mu);
	return len == 0 ? MBEDTLS_ERR_SSL_WANT_READ : (int) len;
}

typedef struct {
	cx_rw_pipe c2s, s2c;
	cx_rw_end send_srv, send_cli;
	mbedtls_entropy_context ent;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_x509_crt crt;
	mbedtls_pk_context key;
	mbedtls_ssl_config sconf, cconf;
	mbedtls_ssl_context srv, cli;
} cx_rw_pair;

static void cx_rw_free(cx_rw_pair *t) {
	mbedtls_ssl_free(&t->cli);
	mbedtls_ssl_free(&t->srv);
	mbedtls_ssl_config_free(&t->cconf);
	mbedtls_ssl_config_free(&t->sconf);
	mbedtls_pk_free(&t->key);
	mbedtls_x509_crt_free(&t->crt);
	mbedtls_ctr_drbg_free(&t->drbg);
	mbedtls_entropy_free(&t->ent);
	pthread_mutex_destroy(&t->c2s.mu);
	pthread_mutex_destroy(&t->s2c.mu);
}

// a client and a server with their TLS 1.3 handshake done over the pipes
static int cx_rw_open(cx_rw_pair *t, const char *cert_pem, const char *key_pem) {
	memset(t, 0, sizeof(*t));
	pthread_mutex_init(&t->c2s.mu, NULL);
	pthread_mutex_init(&t->s2c.mu, NULL);
	t->send_srv.tx = &t->s2c;
	t->send_srv.rx = &t->c2s;
	t->send_cli.tx = &t->c2s;
	t->send_cli.rx = &t->s2c;
	if (psa_crypto_init() != PSA_SUCCESS) return 1;
	mbedtls_entropy_init(&t->ent);
	mbedtls_ctr_drbg_init(&t->drbg);
	mbedtls_x509_crt_init(&t->crt);
	mbedtls_pk_init(&t->key);
	mbedtls_ssl_config_init(&t->sconf);
	mbedtls_ssl_config_init(&t->cconf);
	mbedtls_ssl_init(&t->srv);
	mbedtls_ssl_init(&t->cli);
	if (mbedtls_ctr_drbg_seed(&t->drbg, mbedtls_entropy_func, &t->ent, NULL, 0) != 0) return 2;
	if (mbedtls_x509_crt_parse(&t->crt, (const unsigned char *) cert_pem, strlen(cert_pem) + 1) != 0) return 3;
	if (mbedtls_pk_parse_key(&t->key, (const unsigned char *) key_pem, strlen(key_pem) + 1, NULL, 0,
	                         mbedtls_ctr_drbg_random, &t->drbg) != 0) return 4;
	if (mbedtls_ssl_config_defaults(&t->sconf, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0 ||
	    mbedtls_ssl_config_defaults(&t->cconf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0) return 5;
	mbedtls_ssl_conf_rng(&t->sconf, mbedtls_ctr_drbg_random, &t->drbg);
	mbedtls_ssl_conf_rng(&t->cconf, mbedtls_ctr_drbg_random, &t->drbg);
	mbedtls_ssl_conf_min_tls_version(&t->sconf, MBEDTLS_SSL_VERSION_TLS1_3);
	mbedtls_ssl_conf_min_tls_version(&t->cconf, MBEDTLS_SSL_VERSION_TLS1_3);
	mbedtls_ssl_conf_authmode(&t->cconf, MBEDTLS_SSL_VERIFY_NONE);
#if defined(MBEDTLS_SSL_SESSION_TICKETS)
	mbedtls_ssl_conf_session_tickets(&t->cconf, MBEDTLS_SSL_SESSION_TICKETS_DISABLED);
#endif
	if (mbedtls_ssl_conf_own_cert(&t->sconf, &t->crt, &t->key) != 0) return 6;
	if (mbedtls_ssl_setup(&t->srv, &t->sconf) != 0 || mbedtls_ssl_setup(&t->cli, &t->cconf) != 0) return 7;
	mbedtls_ssl_set_bio(&t->srv, &t->send_srv, cx_rw_send, cx_rw_recv, NULL);
	mbedtls_ssl_set_bio(&t->cli, &t->send_cli, cx_rw_send, cx_rw_recv, NULL);
	int cdone = 0, sdone = 0;
	for (int round = 0; round < 64 && !(cdone && sdone); round++) {
		if (!cdone) {
			int r = mbedtls_ssl_handshake(&t->cli);
			if (r == 0) cdone = 1;
			else if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) return 8;
		}
		if (!sdone) {
			int r = mbedtls_ssl_handshake(&t->srv);
			if (r == 0) sdone = 1;
			else if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) return 9;
		}
	}
	return (cdone && sdone) ? 0 : 10;
}

typedef struct {
	unsigned char *buf;
	size_t len;
	unsigned char *msg, *len_p, *iv;
} cx_rw_dir;

static cx_rw_dir cx_rw_in(mbedtls_ssl_context *s) {
	cx_rw_dir d = {s->private_in_buf, s->private_in_buf_len, s->private_in_msg, s->private_in_len, s->private_in_iv};
	return d;
}

static cx_rw_dir cx_rw_out(mbedtls_ssl_context *s) {
	cx_rw_dir d = {s->private_out_buf, s->private_out_buf_len, s->private_out_msg, s->private_out_len, s->private_out_iv};
	return d;
}

static int cx_rw_same(cx_rw_dir a, cx_rw_dir b) {
	return a.buf == b.buf && a.len == b.len && a.msg == b.msg && a.len_p == b.len_p && a.iv == b.iv;
}

// out: [0] the output buffer survived a whole read that ran while a write had
// grown it (1/0), [1] the input buffer survived a whole write that ran while a
// read had grown it (1/0), [2] the output buffer's length when the read ran,
// [3] the input buffer's length when the write ran.
static int cx_rw_interleave(const char *cert_pem, const char *key_pem, int *out) {
	static cx_rw_pair t;
	unsigned char buf[64];
	for (int i = 0; i < 4; i++) out[i] = -1;
	int rc = cx_rw_open(&t, cert_pem, key_pem);
	if (rc != 0) {
		cx_rw_free(&t);
		return rc;
	}
#if defined(MBEDTLS_SSL_CX_RELEASE_BUFFERS)
	// the writer has entered mbedtls_ssl_write: the output buffer is full size
	mbedtls_ssl_cx_grow_out(&t.srv);
	cx_rw_dir o = cx_rw_out(&t.srv);
	out[2] = (int) o.len;
	// meanwhile the reader runs a whole read (nothing has arrived)
	int r = mbedtls_ssl_read(&t.srv, buf, sizeof(buf));
	if (r != MBEDTLS_ERR_SSL_WANT_READ) rc = 11;
	out[0] = cx_rw_same(o, cx_rw_out(&t.srv));

	// the reader has met a record larger than the idle input buffer
	mbedtls_ssl_cx_grow_in(&t.srv);
	cx_rw_dir in = cx_rw_in(&t.srv);
	out[3] = (int) in.len;
	// meanwhile the writer runs a whole write
	r = mbedtls_ssl_write(&t.srv, (const unsigned char *) "ping", 4);
	if (r != 4 && rc == 0) rc = 12;
	out[1] = cx_rw_same(in, cx_rw_in(&t.srv));
#else
	out[0] = out[1] = 1;
#endif
	cx_rw_free(&t);
	return rc;
}

typedef struct {
	mbedtls_ssl_context *ssl;
	int n, rounds;
	int err;
	volatile int *stop;
} cx_rw_job;

static void cx_rw_fill(unsigned char *m, int n, int seed) {
	for (int i = 0; i < n; i++) m[i] = (unsigned char) ((i * 7 + seed) % 251);
}

// the record sizes cycle from under the idle buffers to past a full record
static int cx_rw_size(int round) {
	static const int sizes[] = {100, 3000, 17000, 700, 9000, 40};
	return sizes[round % 6];
}

static void *cx_rw_writer(void *arg) {
	cx_rw_job *j = (cx_rw_job *) arg;
	static unsigned char m[17000];
	for (int round = 0; round < j->rounds && !*j->stop; round++) {
		int n = cx_rw_size(round);
		cx_rw_fill(m, n, round);
		int off = 0;
		while (off < n && !*j->stop) {
			int r = mbedtls_ssl_write(j->ssl, m + off, (size_t) (n - off));
			if (r > 0) off += r;
			else if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) sched_yield();
			else { j->err = r; *j->stop = 1; return NULL; }
		}
	}
	return NULL;
}

// the client: one thread, alternating its write and its read
typedef struct {
	cx_rw_job w, r;
} cx_rw_client;

static void *cx_rw_client_pump(void *arg) {
	cx_rw_client *c = (cx_rw_client *) arg;
	static unsigned char m[17000], want[17000], got[17000];
	int wround = 0, woff = 0, rround = 0, rd = 0;
	while (!*c->w.stop && (wround < c->w.rounds || rround < c->r.rounds)) {
		int progressed = 0;
		if (wround < c->w.rounds) {
			int n = cx_rw_size(wround);
			if (woff == 0) cx_rw_fill(m, n, wround + 1000);
			int r = mbedtls_ssl_write(c->w.ssl, m + woff, (size_t) (n - woff));
			if (r > 0) {
				woff += r;
				progressed = 1;
				if (woff == n) { wround++; woff = 0; }
			} else if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) {
				c->w.err = r; *c->w.stop = 1; break;
			}
		}
		if (rround < c->r.rounds) {
			int n = cx_rw_size(rround);
			int r = mbedtls_ssl_read(c->r.ssl, got + rd, (size_t) (n - rd));
			if (r > 0) {
				rd += r;
				progressed = 1;
				if (rd == n) {
					cx_rw_fill(want, n, rround);
					if (memcmp(want, got, (size_t) n) != 0) { c->r.err = -1; *c->r.stop = 1; break; }
					rround++;
					rd = 0;
				}
			} else if (r != MBEDTLS_ERR_SSL_WANT_READ && r != MBEDTLS_ERR_SSL_WANT_WRITE) {
				c->r.err = r; *c->r.stop = 1; break;
			}
		}
		if (!progressed) sched_yield();
	}
	return NULL;
}

// The server's writer sends rounds messages (seed = round) to the client, the
// client sends rounds messages (seed = round + 1000) to the server's reader.
// out: [0] server reader error, [1] server writer error, [2] client error
// (0 = every byte crossed intact, -1 = a message arrived corrupted).
static void *cx_rw_srv_reader(void *arg) {
	cx_rw_job *j = (cx_rw_job *) arg;
	static unsigned char want[17000], got[17000];
	for (int round = 0; round < j->rounds && !*j->stop; round++) {
		int n = cx_rw_size(round);
		cx_rw_fill(want, n, round + 1000);
		int rd = 0;
		while (rd < n && !*j->stop) {
			int r = mbedtls_ssl_read(j->ssl, got + rd, (size_t) (n - rd));
			if (r > 0) rd += r;
			else if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE) sched_yield();
			else { j->err = r; *j->stop = 1; return NULL; }
		}
		if (rd == n && memcmp(want, got, (size_t) n) != 0) { j->err = -1; *j->stop = 1; return NULL; }
	}
	return NULL;
}

static int cx_rw_threads(const char *cert_pem, const char *key_pem, int rounds, int *out) {
	static cx_rw_pair t;
	volatile int stop = 0;
	out[0] = out[1] = out[2] = 0;
	int rc = cx_rw_open(&t, cert_pem, key_pem);
	if (rc != 0) {
		cx_rw_free(&t);
		return rc;
	}
	cx_rw_job sr = {&t.srv, 0, rounds, 0, &stop};
	cx_rw_job sw = {&t.srv, 0, rounds, 0, &stop};
	cx_rw_client cl = {{&t.cli, 0, rounds, 0, &stop}, {&t.cli, 0, rounds, 0, &stop}};
	pthread_t a, b, c;
	pthread_create(&a, NULL, cx_rw_srv_reader, &sr);
	pthread_create(&b, NULL, cx_rw_writer, &sw);
	pthread_create(&c, NULL, cx_rw_client_pump, &cl);
	pthread_join(a, NULL);
	pthread_join(b, NULL);
	pthread_join(c, NULL);
	out[0] = sr.err;
	out[1] = sw.err;
	out[2] = cl.w.err != 0 ? cl.w.err : cl.r.err;
	cx_rw_free(&t);
	return 0;
}
