// vgc_data_tables.h — test hooks for vgc_data_tables_test.v (cx-home/v#15
// lever 5): plant a word in vgc_addr_map2 (vgc_platform.h, included first by
// builtin), and a .bss table whose pages the test writes at chosen times.
#ifndef VGC_DATA_TABLES_H
#define VGC_DATA_TABLES_H
#include <stdint.h>
#include <string.h>
// four uint16 entries at the top of the map (chunks past 4 TB, which no arena
// reaches) read together as one 64-bit word holding p
static inline void vgc_dtab_plant(void* p) {
    uint64_t v = (uint64_t)(uintptr_t)p;
    memcpy(&vgc_addr_map2[65532], &v, sizeof(v));
}
static inline void vgc_dtab_unplant(void) {
    memset(&vgc_addr_map2[65532], 0, 4 * sizeof(uint16_t));
}
static inline uint64_t vgc_dtab_planted(void) {
    uint64_t v;
    memcpy(&v, &vgc_addr_map2[65532], sizeof(v));
    return v;
}
static void* vgc_dtab_table[1 << 18]; // 2 MB of .bss
static inline void vgc_dtab_set(int i, void* p) { vgc_dtab_table[i] = p; }
static inline void* vgc_dtab_get(int i) { return vgc_dtab_table[i]; }
#endif
