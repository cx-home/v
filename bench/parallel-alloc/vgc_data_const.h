// vgc_data_const.h — the main image's __DATA_CONST range and its protection,
// for vgc_data_const_test.v (cx-home/v#15).
#ifndef VGC_DATA_CONST_H
#define VGC_DATA_CONST_H
#include <stdint.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
static inline uintptr_t vgc_dc_bound(int hi) {
    unsigned long sz = 0;
    uint8_t* p = getsegmentdata((const struct mach_header_64*)_dyld_get_image_header(0), "__DATA_CONST", &sz);
    if (p == 0 || sz == 0) return 0;
    return hi ? (uintptr_t)p + (uintptr_t)sz : (uintptr_t)p;
}
// 1 = writable now, 0 = read-only, -1 = unknown (no segment, or vm_region refused).
static inline int vgc_dc_writable(void) {
    uintptr_t lo = vgc_dc_bound(0);
    if (lo == 0) return -1;
    mach_vm_address_t a = (mach_vm_address_t)lo;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (mach_vm_region(mach_task_self(), &a, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return -1;
    if (a > (mach_vm_address_t)lo) return -1;
    return (info.protection & VM_PROT_WRITE) ? 1 : 0;
}
#else
static inline uintptr_t vgc_dc_bound(int hi) { (void)hi; return 0; }
static inline int vgc_dc_writable(void) { return -1; }
#endif
#endif
