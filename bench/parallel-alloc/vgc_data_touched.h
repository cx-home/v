// vgc_data_touched.h — the .bss tables of vgc_data_touched_test.v (cx-home/v#15, cx-home/v#85).
#ifndef VGC_DATA_TOUCHED_H
#define VGC_DATA_TOUCHED_H
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
#define VGC_DT_SLOTS (1 << 20)
#define VGC_DT_HUGE_SLOTS (1 << 24)
// 8 MB of zero-fill .bss that the program writes only where a case says so.
static void* vgc_dt_big[VGC_DT_SLOTS];
// cx-home/v#85: 128 MB of the same — 8,192 pages of 16 KB, 32,768 of 4 KB: more
// than one 1,024-page mincore block on either page size, whatever the number of
// markers the data segment is sliced across.
static void* vgc_dt_huge[VGC_DT_HUGE_SLOTS];
static inline void* vgc_dt_get(int i) { return vgc_dt_big[i]; }
static inline void vgc_dt_set(int i, void* p) { vgc_dt_big[i] = p; }
static inline void* vgc_dt_huge_get(int i) { return vgc_dt_huge[i]; }
static inline void vgc_dt_huge_set(int i, void* p) { vgc_dt_huge[i] = p; }
// Pages of a table in core, or -1 where mincore has no paged-out bit (the
// collector scans the whole range there; only the survival case applies).
static inline int vgc_dt_resident_in(void** tab, size_t slots) {
#if defined(__APPLE__) && defined(MINCORE_PAGED_OUT)
    // Only the pages wholly inside the table: its first and last page may be
    // shared with neighbouring .bss words the program writes.
    static unsigned char vec[VGC_DT_HUGE_SLOTS * sizeof(void*) / 4096 + 2];
    long ps = getpagesize();
    uintptr_t lo = ((uintptr_t)&tab[0] + ps - 1) & ~(uintptr_t)(ps - 1);
    uintptr_t hi = (uintptr_t)&tab[slots] & ~(uintptr_t)(ps - 1);
    if (hi <= lo) return -1;
    size_t n = (size_t)((hi - lo) / ps);
    if (n > sizeof(vec)) return -1;
    if (mincore((caddr_t)lo, n * ps, (char*)vec) != 0) return -1;
    int r = 0;
    for (size_t i = 0; i < n; i++) if (vec[i] & MINCORE_INCORE) r++;
    return r;
#else
    (void)tab; (void)slots;
    return -1;
#endif
}
static inline int vgc_dt_resident_pages(void) { return vgc_dt_resident_in(vgc_dt_big, VGC_DT_SLOTS); }
static inline int vgc_dt_huge_resident_pages(void) { return vgc_dt_resident_in(vgc_dt_huge, VGC_DT_HUGE_SLOTS); }
#endif
