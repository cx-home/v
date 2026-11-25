// cx-home/cx-platform-net#29 lever 10: a TLS 1.3 server's handshakes all pass through
// mbedtls PSA's global key-slot mutex (psa_get_and_lock_key_slot /
// psa_unregister_read_under_mutex under psa_generate_key, psa_export_public_key,
// psa_raw_key_agreement, psa_destroy_key). The probe runs that key cycle -- the
// ephemeral X25519 share and the HKDF key schedule of one handshake -- on N threads at once and reads the
// lock counters of thirdparty/mbedtls/library/threading.c: how many locks found
// the mutex held and parked, and the process's context switches, per cycle.
#include <psa/crypto.h>
#include <pthread.h>
#include <string.h>
#include <sys/resource.h>

#if defined(MBEDTLS_THREADING_PTHREAD)
extern unsigned long long v_mbedtls_mutex_acquires;
extern unsigned long long v_mbedtls_mutex_parks;
#endif

typedef struct {
	int iters;
	int failed;
} cx_mc_arg;

static int cx_mc_go = 0;

static uint8_t cx_mc_peer[32];

// TLS 1.3's key schedule (RFC 8446 7.1) on a full handshake: ~12 HKDF-Extract/Expand-Label steps
#define CX_MC_HKDF_STEPS 12

static void *cx_mc_worker(void *p) {
	cx_mc_arg *a = (cx_mc_arg *)p;
	uint8_t pub[32], out[32], mac[32];
	size_t n = 0;
	memset(out, 7, sizeof out);
	psa_key_attributes_t ha = psa_key_attributes_init();
	psa_set_key_type(&ha, PSA_KEY_TYPE_HMAC);
	psa_set_key_bits(&ha, 256);
	psa_set_key_usage_flags(&ha, PSA_KEY_USAGE_SIGN_MESSAGE);
	psa_set_key_algorithm(&ha, PSA_ALG_HMAC(PSA_ALG_SHA_256));
	psa_key_attributes_t at = psa_key_attributes_init();
	psa_set_key_type(&at, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_MONTGOMERY));
	psa_set_key_bits(&at, 255);
	psa_set_key_usage_flags(&at, PSA_KEY_USAGE_DERIVE);
	psa_set_key_algorithm(&at, PSA_ALG_ECDH);
	while (!__atomic_load_n(&cx_mc_go, __ATOMIC_ACQUIRE)) {
	}
	for (int i = 0; i < a->iters; i++) {
		psa_key_id_t id = 0;
		if (psa_generate_key(&at, &id) != PSA_SUCCESS) { a->failed++; continue; }
		if (psa_export_public_key(id, pub, 32, &n) != PSA_SUCCESS) a->failed++;
		if (psa_raw_key_agreement(PSA_ALG_ECDH, id, cx_mc_peer, 32, out, 32, &n) != PSA_SUCCESS) a->failed++;
		psa_destroy_key(id);
		// the key schedule: HKDF-Extract/Expand steps import an HMAC key, MAC, destroy
		for (int k = 0; k < CX_MC_HKDF_STEPS; k++) {
			psa_key_id_t h = 0;
			if (psa_import_key(&ha, out, 32, &h) != PSA_SUCCESS) { a->failed++; continue; }
			if (psa_mac_compute(h, PSA_ALG_HMAC(PSA_ALG_SHA_256), pub, 32, mac, sizeof mac, &n) != PSA_SUCCESS) a->failed++;
			psa_destroy_key(h);
		}
	}
	return NULL;
}

static long cx_mc_csw(void) {
	struct rusage r;
	getrusage(RUSAGE_SELF, &r);
	return r.ru_nvcsw + r.ru_nivcsw;
}

// runs threads x iters key cycles; returns the failed PSA calls (0 = all good) or < 0 on a
// setup failure; *acq / *parks / *csw = per cycle
static int cx_mc_run(int threads, int iters, double *acq, double *parks, double *csw) {
	if (psa_crypto_init() != PSA_SUCCESS) return -1;
	// a valid peer share: the public key of a fixed private key
	{
		psa_key_attributes_t at = psa_key_attributes_init();
		psa_set_key_type(&at, PSA_KEY_TYPE_ECC_KEY_PAIR(PSA_ECC_FAMILY_MONTGOMERY));
		psa_set_key_bits(&at, 255);
		psa_set_key_usage_flags(&at, PSA_KEY_USAGE_DERIVE);
		psa_set_key_algorithm(&at, PSA_ALG_ECDH);
		psa_key_id_t id = 0;
		size_t n = 0;
		if (psa_generate_key(&at, &id) != PSA_SUCCESS) return -2;
		if (psa_export_public_key(id, cx_mc_peer, 32, &n) != PSA_SUCCESS) return -3;
		psa_destroy_key(id);
	}
	if (threads > 64) threads = 64;
	pthread_t th[64];
	cx_mc_arg args[64];
	__atomic_store_n(&cx_mc_go, 0, __ATOMIC_RELEASE);
	unsigned long long a0 = 0, p0 = 0;
#if defined(MBEDTLS_THREADING_PTHREAD)
	a0 = __atomic_load_n(&v_mbedtls_mutex_acquires, __ATOMIC_RELAXED);
	p0 = __atomic_load_n(&v_mbedtls_mutex_parks, __ATOMIC_RELAXED);
#endif
	for (int i = 0; i < threads; i++) {
		args[i].iters = iters;
		args[i].failed = 0;
		pthread_create(&th[i], NULL, cx_mc_worker, &args[i]);
	}
	long c0 = cx_mc_csw();
	__atomic_store_n(&cx_mc_go, 1, __ATOMIC_RELEASE);
	int failed = 0;
	for (int i = 0; i < threads; i++) {
		pthread_join(th[i], NULL);
		failed += args[i].failed;
	}
	long c1 = cx_mc_csw();
	double cycles = (double)threads * (double)iters;
#if defined(MBEDTLS_THREADING_PTHREAD)
	*acq = (double)(__atomic_load_n(&v_mbedtls_mutex_acquires, __ATOMIC_RELAXED) - a0) / cycles;
	*parks = (double)(__atomic_load_n(&v_mbedtls_mutex_parks, __ATOMIC_RELAXED) - p0) / cycles;
#else
	*acq = -1;
	*parks = -1;
#endif
	*csw = (double)(c1 - c0) / cycles;
	return failed;
}
