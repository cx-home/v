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
// one mutex for all shared state: tcc (the default cc of the Linux/FreeBSD
// CI rows) has no atomic builtins
static pthread_mutex_t vna_mu = PTHREAD_MUTEX_INITIALIZER;
static void vna_add(int* c) { pthread_mutex_lock(&vna_mu); (*c)++; pthread_mutex_unlock(&vna_mu); }
static uintptr_t vna_get(uintptr_t* v) { pthread_mutex_lock(&vna_mu); uintptr_t r = *v; pthread_mutex_unlock(&vna_mu); return r; }
static void vna_set(uintptr_t* v, uintptr_t x) { pthread_mutex_lock(&vna_mu); *v = x; pthread_mutex_unlock(&vna_mu); }
static int vna_geti(int* v) { pthread_mutex_lock(&vna_mu); int r = *v; pthread_mutex_unlock(&vna_mu); return r; }
static uintptr_t vna_pinned_masked;

static void vna_reset(int mode) {
    memset(vna_slot, 0, sizeof vna_slot);
    vna_holding = vna_release = vna_bad = vna_new = vna_again = 0;
    vna_mode = mode;
}

static void* vna_thread(void* arg) {
    int i = (int)(intptr_t)arg;
    if (vna_mode >= 1) {
        if (vgc_thread_attach() == 1) vna_add(&vna_new);
        if (vgc_thread_attach() == 0) vna_add(&vna_again);
    }
    uintptr_t m;
    while ((m = vna_get(&vna_slot[i])) == 0) usleep(100);
    unsigned char* volatile p = (unsigned char*)(m ^ VNA_MASK);
    vna_set(&vna_slot[i], 0);
    m = 0;
    vna_add(&vna_holding);
    while (!vna_geti(&vna_release)) usleep(1000);
    for (int k = 0; k < VNA_LEN; k++) {
        if (p[k] != (unsigned char)(0xA0 + i)) { vna_add(&vna_bad); break; }
    }
    if (vna_mode == 2) vgc_thread_detach();
    return 0;
}

static void vna_set_release(void) { pthread_mutex_lock(&vna_mu); vna_release = 1; pthread_mutex_unlock(&vna_mu); }

void vna_start(int mode) {
    vna_reset(mode);
    for (int i = 0; i < VNA_N; i++) pthread_create(&vna_tid[i], 0, vna_thread, (void*)(intptr_t)i);
}
void vna_hand(int i, void* p) { vna_set(&vna_slot[i], (uintptr_t)p ^ VNA_MASK); }
int vna_holding_n(void) { return vna_geti(&vna_holding); }
int vna_finish(void) {
    vna_set_release();
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
