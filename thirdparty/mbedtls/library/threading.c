/*
 *  Threading abstraction layer
 *
 *  Copyright The Mbed TLS Contributors
 *  SPDX-License-Identifier: Apache-2.0 OR GPL-2.0-or-later
 */

/*
 * Ensure gmtime_r is available even with -std=c99; must be defined before
 * mbedtls_config.h, which pulls in glibc's features.h. Harmless on other platforms.
 */
#if !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200112L
#endif

#include "common.h"

#if defined(MBEDTLS_THREADING_C)

#include "threading_internal.h"

#if defined(MBEDTLS_HAVE_TIME_DATE) && !defined(MBEDTLS_PLATFORM_GMTIME_R_ALT)

#if defined(MBEDTLS_PLATFORM_IS_UNIXLIKE)
#include <unistd.h>
#endif /* !_WIN32 && (unix || __unix || __unix__ ||
        * (__APPLE__ && __MACH__)) */

#if !((defined(_POSIX_VERSION) && _POSIX_VERSION >= 200809L) ||     \
    (defined(_POSIX_THREAD_SAFE_FUNCTIONS) &&                     \
    _POSIX_THREAD_SAFE_FUNCTIONS >= 200112L))
/*
 * This is a convenience shorthand macro to avoid checking the long
 * preprocessor conditions above. Ideally, we could expose this macro in
 * platform_util.h and simply use it in platform_util.c, threading.c and
 * threading.h. However, this macro is not part of the Mbed TLS public API, so
 * we keep it private by only defining it in this file
 */

#if !(defined(_WIN32) && !defined(EFIX64) && !defined(EFI32))
#define THREADING_USE_GMTIME
#endif /* ! ( defined(_WIN32) && !defined(EFIX64) && !defined(EFI32) ) */

#endif /* !( ( defined(_POSIX_VERSION) && _POSIX_VERSION >= 200809L ) || \
             ( defined(_POSIX_THREAD_SAFE_FUNCTIONS ) && \
                _POSIX_THREAD_SAFE_FUNCTIONS >= 200112L ) ) */

#endif /* MBEDTLS_HAVE_TIME_DATE && !MBEDTLS_PLATFORM_GMTIME_R_ALT */

#if defined(MBEDTLS_THREADING_PTHREAD)
static void threading_mutex_init_pthread(mbedtls_threading_mutex_t *mutex)
{
    if (mutex == NULL) {
        return;
    }

    /* One problem here is that calling lock on a pthread mutex without first
     * having initialised it is undefined behaviour. Obviously we cannot check
     * this here in a thread safe manner without a significant performance
     * hit, so state transitions are checked in tests only via the state
     * variable. Please make sure any new mutex that gets added is exercised in
     * tests; see framework/tests/src/threading_helpers.c for more details. */
#if defined(__APPLE__) && defined(PTHREAD_MUTEX_POLICY_FIRSTFIT_NP)
    /* cx-home/cx-platform-net#29 lever 10: first-fit, as MUTEX_INIT below */
    pthread_mutexattr_t attr;
    if (pthread_mutexattr_init(&attr) == 0) {
        (void) pthread_mutexattr_setpolicy_np(&attr, PTHREAD_MUTEX_POLICY_FIRSTFIT_NP);
        (void) pthread_mutex_init(&mutex->mutex, &attr);
        (void) pthread_mutexattr_destroy(&attr);
        return;
    }
#endif
    (void) pthread_mutex_init(&mutex->mutex, NULL);
}

static void threading_mutex_free_pthread(mbedtls_threading_mutex_t *mutex)
{
    if (mutex == NULL) {
        return;
    }

    (void) pthread_mutex_destroy(&mutex->mutex);
}

/* cx-home/cx-platform-net#29: every lock (v_mbedtls_mutex_acquires) and every lock that
 * found the mutex held and went to pthread_mutex_lock to wait (v_mbedtls_mutex_parks) --
 * read by vlib/net/mbedtls/mbedtls_mutex_contention_test.v. */
unsigned long long v_mbedtls_mutex_acquires = 0;
unsigned long long v_mbedtls_mutex_parks = 0;
#if defined(__APPLE__)
#include <mach/mach_time.h>
/* cx-home/cx-platform-net#29 lever 11: the spin before a park is bounded in TIME, not in
 * tries: lever 10's 64 tries x 32 relaxes lasted 73 us on x86 (ardec-dev3, pause) but 0.46 us
 * on arm64 (dev1 M2 Max, yield is ~1 cycle) -- shorter than a queue of 16 threads' key-slot
 * holds, so arm64 still parked ~1.1 times a TLS 1.3 handshake on dev2. 75 us = x86's budget. */
#define V_MBEDTLS_SPIN_NS 75000ull
static volatile uint64_t v_mbedtls_spin_ticks = 0; /* every thread computes the same value */
static uint64_t v_mbedtls_spin_budget(void)
{
    uint64_t t = v_mbedtls_spin_ticks;
    if (t == 0) {
        mach_timebase_info_data_t tb;
        if (mach_timebase_info(&tb) != 0 || tb.numer == 0) {
            tb.numer = 1;
            tb.denom = 1;
        }
        t = V_MBEDTLS_SPIN_NS * tb.denom / tb.numer;
        if (t == 0) {
            t = 1;
        }
        v_mbedtls_spin_ticks = t;
    }
    return t;
}
#if defined(__aarch64__) && !defined(__TINYC__)
#define V_MBEDTLS_CPU_RELAX() __asm__ __volatile__ ("yield")
#elif (defined(__x86_64__) || defined(__i386__)) && !defined(__TINYC__)
#define V_MBEDTLS_CPU_RELAX() __asm__ __volatile__ ("pause")
#else
#define V_MBEDTLS_CPU_RELAX() ((void) 0)
#endif
#endif
#if defined(__TINYC__)
#define V_MBEDTLS_COUNT(c) ((c)++)
#else
#define V_MBEDTLS_COUNT(c) __atomic_fetch_add(&(c), 1, __ATOMIC_RELAXED)
#endif

static int threading_mutex_lock_pthread(mbedtls_threading_mutex_t *mutex)
{
    if (mutex == NULL) {
        return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
    }

    V_MBEDTLS_COUNT(v_mbedtls_mutex_acquires);
    if (pthread_mutex_trylock(&mutex->mutex) == 0) {
        return 0;
    }
#if defined(__APPLE__)
    /* cx-home/cx-platform-net#29 lever 10: the hot holders (PSA's key-slot table) keep the
     * mutex for a lookup, far less than a park and the two context switches it costs: pause
     * a few dozen cycles and retry before parking -- lever 11: for up to V_MBEDTLS_SPIN_NS. */
    uint64_t deadline = mach_absolute_time() + v_mbedtls_spin_budget();
    for (;;) {
        for (int k = 0; k < 32; k++) {
            V_MBEDTLS_CPU_RELAX();
        }
        if (pthread_mutex_trylock(&mutex->mutex) == 0) {
            return 0;
        }
        if (mach_absolute_time() >= deadline) {
            break;
        }
    }
#endif
    V_MBEDTLS_COUNT(v_mbedtls_mutex_parks);
    if (pthread_mutex_lock(&mutex->mutex) != 0) {
        return MBEDTLS_ERR_THREADING_MUTEX_ERROR;
    }

    return 0;
}

static int threading_mutex_unlock_pthread(mbedtls_threading_mutex_t *mutex)
{
    if (mutex == NULL) {
        return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
    }

    if (pthread_mutex_unlock(&mutex->mutex) != 0) {
        return MBEDTLS_ERR_THREADING_MUTEX_ERROR;
    }

    return 0;
}

void (*mbedtls_mutex_init)(mbedtls_threading_mutex_t *) = threading_mutex_init_pthread;
void (*mbedtls_mutex_free)(mbedtls_threading_mutex_t *) = threading_mutex_free_pthread;
int (*mbedtls_mutex_lock)(mbedtls_threading_mutex_t *) = threading_mutex_lock_pthread;
int (*mbedtls_mutex_unlock)(mbedtls_threading_mutex_t *) = threading_mutex_unlock_pthread;

/*
 * With pthreads we can statically initialize mutexes
 */
#if defined(__APPLE__) && defined(PTHREAD_FIRSTFIT_MUTEX_INITIALIZER)
/* cx-home/cx-platform-net#29 lever 10: darwin's default (fair-share) mutex hands a released
 * mutex to the oldest parked waiter, so under contention every acquire becomes a handoff
 * through the kernel; a first-fit mutex lets a running thread take it. */
#define MUTEX_INIT  = { PTHREAD_FIRSTFIT_MUTEX_INITIALIZER, 1 }
#else
#define MUTEX_INIT  = { PTHREAD_MUTEX_INITIALIZER, 1 }
#endif

#endif /* MBEDTLS_THREADING_PTHREAD */

#if defined(MBEDTLS_THREADING_ALT)
static int threading_mutex_fail(mbedtls_threading_mutex_t *mutex)
{
    ((void) mutex);
    return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
}
static void threading_mutex_dummy(mbedtls_threading_mutex_t *mutex)
{
    ((void) mutex);
    return;
}

void (*mbedtls_mutex_init)(mbedtls_threading_mutex_t *) = threading_mutex_dummy;
void (*mbedtls_mutex_free)(mbedtls_threading_mutex_t *) = threading_mutex_dummy;
int (*mbedtls_mutex_lock)(mbedtls_threading_mutex_t *) = threading_mutex_fail;
int (*mbedtls_mutex_unlock)(mbedtls_threading_mutex_t *) = threading_mutex_fail;

/*
 * Set functions pointers and initialize global mutexes
 */
void mbedtls_threading_set_alt(void (*mutex_init)(mbedtls_threading_mutex_t *),
                               void (*mutex_free)(mbedtls_threading_mutex_t *),
                               int (*mutex_lock)(mbedtls_threading_mutex_t *),
                               int (*mutex_unlock)(mbedtls_threading_mutex_t *))
{
    mbedtls_mutex_init = mutex_init;
    mbedtls_mutex_free = mutex_free;
    mbedtls_mutex_lock = mutex_lock;
    mbedtls_mutex_unlock = mutex_unlock;

#if defined(MBEDTLS_FS_IO)
    mbedtls_mutex_init(&mbedtls_threading_readdir_mutex);
#endif
#if defined(THREADING_USE_GMTIME)
    mbedtls_mutex_init(&mbedtls_threading_gmtime_mutex);
#endif
#if defined(MBEDTLS_PSA_CRYPTO_C)
    mbedtls_mutex_init(&mbedtls_threading_key_slot_mutex);
    mbedtls_mutex_init(&mbedtls_threading_psa_globaldata_mutex);
    mbedtls_mutex_init(&mbedtls_threading_psa_rngdata_mutex);
#endif
}

/*
 * Free global mutexes
 */
void mbedtls_threading_free_alt(void)
{
#if defined(MBEDTLS_FS_IO)
    mbedtls_mutex_free(&mbedtls_threading_readdir_mutex);
#endif
#if defined(THREADING_USE_GMTIME)
    mbedtls_mutex_free(&mbedtls_threading_gmtime_mutex);
#endif
#if defined(MBEDTLS_PSA_CRYPTO_C)
    mbedtls_mutex_free(&mbedtls_threading_key_slot_mutex);
    mbedtls_mutex_free(&mbedtls_threading_psa_globaldata_mutex);
    mbedtls_mutex_free(&mbedtls_threading_psa_rngdata_mutex);
#endif
}
#endif /* MBEDTLS_THREADING_ALT */

/*
 * Define global mutexes
 */
#ifndef MUTEX_INIT
#define MUTEX_INIT
#endif
#if defined(MBEDTLS_FS_IO)
mbedtls_threading_mutex_t mbedtls_threading_readdir_mutex MUTEX_INIT;
#endif
#if defined(THREADING_USE_GMTIME)
mbedtls_threading_mutex_t mbedtls_threading_gmtime_mutex MUTEX_INIT;
#endif
#if defined(MBEDTLS_PSA_CRYPTO_C)
mbedtls_threading_mutex_t mbedtls_threading_key_slot_mutex MUTEX_INIT;
mbedtls_threading_mutex_t mbedtls_threading_psa_globaldata_mutex MUTEX_INIT;
mbedtls_threading_mutex_t mbedtls_threading_psa_rngdata_mutex MUTEX_INIT;
#endif

#endif /* MBEDTLS_THREADING_C */
