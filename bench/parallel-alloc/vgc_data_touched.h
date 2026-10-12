// vgc_data_touched.h — the .bss table of vgc_data_touched_test.v (cx-home/v#15).
#ifndef VGC_DATA_TOUCHED_H
#define VGC_DATA_TOUCHED_H
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
#define VGC_DT_SLOTS (1 << 20)
// 8 MB of zero-fill .bss that the program writes only where a case says so.
static void* vgc_dt_big[VGC_DT_SLOTS];
static inline void* vgc_dt_get(int i) { return vgc_dt_big[i]; }
static inline void vgc_dt_set(int i, void* p) { vgc_dt_big[i] = p; }
// Pages of the table in core, or -1 where mincore has no paged-out bit (the
// collector scans the whole range there; only the survival case applies).
static inline int vgc_dt_resident_pages(void) {
#if defined(__APPLE__) && defined(MINCORE_PAGED_OUT)
    // Only the pages wholly inside the table: its first and last page may be
    // shared with neighbouring .bss words the program writes.
    unsigned char vec[VGC_DT_SLOTS * sizeof(void*) / 4096 + 2];
    long ps = getpagesize();
    uintptr_t lo = ((uintptr_t)&vgc_dt_big[0] + ps - 1) & ~(uintptr_t)(ps - 1);
    uintptr_t hi = (uintptr_t)&vgc_dt_big[VGC_DT_SLOTS] & ~(uintptr_t)(ps - 1);
    if (hi <= lo) return -1;
    size_t n = (size_t)((hi - lo) / ps);
    if (mincore((caddr_t)lo, n * ps, (char*)vec) != 0) return -1;
    int r = 0;
    for (size_t i = 0; i < n; i++) if (vec[i] & MINCORE_INCORE) r++;
    return r;
#else
    return -1;
#endif
}
#endif
