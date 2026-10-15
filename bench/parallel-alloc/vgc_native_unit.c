// vgc_native_unit.c — a native unit for vgc_native_attach_test.v (NATV-18,
// cx-home/v#47): its own translation unit, compiled by cc apart from the V
// program and linked with it (the test's `#flag @DIR/vgc_native_unit.o`), the
// shape of cx's native defs. It reaches the collector only through
// thirdparty/vgc/vgc_native.h. Each native thread takes one GC buffer through an
// XOR-masked handoff slot (so the data-segment scan sees no pointer), keeps it
// only in a local on its own stack while main collects and churns, then checks
// its bytes.
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include "../../thirdparty/vgc/vgc_native.h"
#include "vgc_native_unit.h"

#define VNA_N 8
#define VNA_LEN 2048
#define VNA_MASK ((uintptr_t)0x5a5a5a5a5a5a5a5aULL)

static uintptr_t vna_slot[VNA_N];
static int vna_holding, vna_release, vna_bad, vna_new, vna_again, vna_mode;
static pthread_t vna_tid[VNA_N];
static uintptr_t vna_pinned_masked;

static void vna_reset(int mode) {
    memset(vna_slot, 0, sizeof vna_slot);
    vna_holding = vna_release = vna_bad = vna_new = vna_again = 0;
    vna_mode = mode;
}

static void* vna_thread(void* arg) {
    int i = (int)(intptr_t)arg;
    if (vna_mode >= 1) {
        if (vgc_thread_attach() == 1) __atomic_add_fetch(&vna_new, 1, __ATOMIC_SEQ_CST);
        if (vgc_thread_attach() == 0) __atomic_add_fetch(&vna_again, 1, __ATOMIC_SEQ_CST);
    }
    uintptr_t m;
    while ((m = __atomic_load_n(&vna_slot[i], __ATOMIC_ACQUIRE)) == 0) usleep(100);
    unsigned char* volatile p = (unsigned char*)(m ^ VNA_MASK);
    __atomic_store_n(&vna_slot[i], 0, __ATOMIC_RELEASE);
    m = 0;
    __atomic_add_fetch(&vna_holding, 1, __ATOMIC_SEQ_CST);
    while (!__atomic_load_n(&vna_release, __ATOMIC_ACQUIRE)) usleep(1000);
    for (int k = 0; k < VNA_LEN; k++) {
        if (p[k] != (unsigned char)(0xA0 + i)) { __atomic_add_fetch(&vna_bad, 1, __ATOMIC_SEQ_CST); break; }
    }
    if (vna_mode == 2) vgc_thread_detach();
    return 0;
}

void vna_start(int mode) {
    vna_reset(mode);
    for (int i = 0; i < VNA_N; i++) pthread_create(&vna_tid[i], 0, vna_thread, (void*)(intptr_t)i);
}
void vna_hand(int i, void* p) { __atomic_store_n(&vna_slot[i], (uintptr_t)p ^ VNA_MASK, __ATOMIC_RELEASE); }
int vna_holding_n(void) { return __atomic_load_n(&vna_holding, __ATOMIC_ACQUIRE); }
int vna_finish(void) {
    __atomic_store_n(&vna_release, 1, __ATOMIC_RELEASE);
    for (int i = 0; i < VNA_N; i++) pthread_join(vna_tid[i], 0);
    return vna_bad;
}
int vna_new_n(void) { return vna_new; }
int vna_again_n(void) { return vna_again; }

// a pinned buffer held only in non-scanned memory (a masked static)
void vna_park(void* p) { vgc_native_pin(p); vna_pinned_masked = (uintptr_t)p ^ VNA_MASK; }
int vna_parked_bad(int byte) {
    unsigned char* p = (unsigned char*)(vna_pinned_masked ^ VNA_MASK);
    for (int k = 0; k < VNA_LEN; k++) if (p[k] != (unsigned char)byte) return 1;
    return 0;
}
void vna_unpark(void) { vgc_native_unpin((void*)(vna_pinned_masked ^ VNA_MASK)); vna_pinned_masked = 0; }

// the store gate on a GC object and on a non-GC address: no call-out
// outside a concurrent mark / the permanent generation, never a crash
void vna_gate(void* obj) { vgc_native_wb_gate(obj); vgc_native_wb_gate((void*)&vna_slot[0]); }
int vna_abi(void) { return vgc_native_abi_1(); }
void vna_safe_roundtrip(void) { vgc_native_safe_enter(); usleep(1000); vgc_native_safe_exit(); }
