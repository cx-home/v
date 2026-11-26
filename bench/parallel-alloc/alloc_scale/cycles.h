// cycles.h — scale.v's C side (cx-private#2040): this process's CPU cycles and
// instructions so far (proc_pid_rusage RUSAGE_INFO_V4; every thread, the
// collector's too), 0 where the counters are not kept; and the no-collector
// hardware control (vgc_as_ring_phase) the test grades the allocator against.
#include <stdint.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <libproc.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
static uint64_t vgc_as_cycles(void) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
    return ri.ri_cycles;
}
static uint64_t vgc_as_instructions(void) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
    return ri.ri_instructions;
}
// The hardware control (operator ruling VGC-SCALE-NET (c), 11-26; v-writer9's
// ring.c shape): each thread writes 32-byte slots (a memset and three stores,
// the fixture's object) through a private ring of ring_bytes, n slots, with no
// collector and no allocator — the cache cost of a per-thread working set of
// that size when threads write at once. Threads are plain pthreads (not the
// collector's: they never allocate from it).
typedef struct { uint64_t a, b; void *n; } vgc_as_slot;
static size_t vgc_as_ring_bytes;
static long vgc_as_ring_n;
static void *vgc_as_ring_work(void *arg) {
    long id = (long)arg;
    char *buf = (char *)malloc(vgc_as_ring_bytes);
    if (buf == 0) return 0;
    memset(buf, 1, vgc_as_ring_bytes);
    size_t slots = vgc_as_ring_bytes / 32, k = 0;
    uint64_t acc = (uint64_t)id;
    void *prev = 0;
    for (long i = 0; i < vgc_as_ring_n; i++) {
        vgc_as_slot *s = (vgc_as_slot *)(buf + k * 32);
        memset(s, 0, 32);
        s->a = acc;
        s->b = (uint64_t)i;
        s->n = prev;
        acc += s->a ^ s->b;
        prev = (i & 7) ? (void *)s : 0;
        if (++k == slots) k = 0;
    }
    free(buf);
    return (void *)(uintptr_t)acc;
}
// cycles per slot of one phase of `threads` threads (0: no counters or no threads)
static double vgc_as_ring_phase(int threads, long n, uint64_t ring_bytes) {
    pthread_t th[256];
    if (threads < 1 || threads > 256 || n < 1 || ring_bytes < 32) return 0;
    vgc_as_ring_bytes = (size_t)ring_bytes;
    vgc_as_ring_n = n;
    uint64_t c0 = vgc_as_cycles();
    int made = 0;
    for (long i = 0; i < threads; i++) {
        if (pthread_create(&th[i], 0, vgc_as_ring_work, (void *)i) != 0) break;
        made++;
    }
    for (int i = 0; i < made; i++) pthread_join(th[i], 0);
    uint64_t c1 = vgc_as_cycles();
    if (made != threads || c0 == 0) return 0;
    return (double)(c1 - c0) / ((double)threads * (double)n);
}
#else
static uint64_t vgc_as_cycles(void) { return 0; }
static uint64_t vgc_as_instructions(void) { return 0; }
static double vgc_as_ring_phase(int threads, long n, uint64_t ring_bytes) { return 0; }
#endif
