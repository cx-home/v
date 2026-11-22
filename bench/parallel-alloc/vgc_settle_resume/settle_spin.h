// settle_spin.h — helpers for vgc_settle_resume_test.v (cx-private#2078).
// A spin loop with no safepoint (C code: the collector can only mach-suspend
// the thread running it), the thread's kernel suspend count, and the atomics
// the test's two threads share.
#ifndef VGC_SETTLE_SPIN_H
#define VGC_SETTLE_SPIN_H
#include <stdint.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#endif

static inline void vgc_settle_spin(volatile int* stop, volatile uint64_t* ctr) {
    while (__atomic_load_n(stop, __ATOMIC_ACQUIRE) == 0) {
        __atomic_add_fetch(ctr, 1, __ATOMIC_RELAXED);
    }
}

// The kernel's suspend count of the thread whose port is `port` (darwin);
// -1 when the port does not answer, -2 on other systems.
static inline int vgc_settle_suspend_count(uint32_t port) {
#if defined(__APPLE__)
    struct thread_basic_info info;
    mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
    if (thread_info((thread_act_t)port, THREAD_BASIC_INFO, (thread_info_t)&info, &cnt) != KERN_SUCCESS) return -1;
    return info.suspend_count;
#else
    (void)port;
    return -2;
#endif
}

// Undo a leaked suspend so a red run still finishes (the test asserts first what it saw).
static inline void vgc_settle_resume_all(uint32_t port) {
#if defined(__APPLE__)
    for (int i = 0; i < 64 && vgc_settle_suspend_count(port) > 0; i++) thread_resume((thread_act_t)port);
#else
    (void)port;
#endif
}

static inline uint32_t vgc_settle_load_u32(volatile uint32_t* p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void vgc_settle_store_u32(volatile uint32_t* p, uint32_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline uint64_t vgc_settle_load_u64(volatile uint64_t* p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void vgc_settle_store_int(volatile int* p, int v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
#endif
