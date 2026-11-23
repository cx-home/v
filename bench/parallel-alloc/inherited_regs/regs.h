// regs.h — inherited.v's C side (cx-home/v#90): the callee-saved registers as main__main
// found them, and whether a page is free address space.
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>
#ifndef MAP_ANONYMOUS
  #define MAP_ANONYMOUS MAP_ANON
#endif
static uint64_t vgc_ir_regs[10];
// The caller's callee-saved registers, read before this function writes any (its one
// pointer is pinned to a scratch register); the count read, 0 on a target not covered.
__attribute__((noinline)) static int vgc_ir_snap(void) {
#if defined(__x86_64__)
    __asm__ __volatile__("movq %%rbx, %0" : "=m"(vgc_ir_regs[0]));
    __asm__ __volatile__("movq %%r12, %0" : "=m"(vgc_ir_regs[1]));
    __asm__ __volatile__("movq %%r13, %0" : "=m"(vgc_ir_regs[2]));
    __asm__ __volatile__("movq %%r14, %0" : "=m"(vgc_ir_regs[3]));
    __asm__ __volatile__("movq %%r15, %0" : "=m"(vgc_ir_regs[4]));
    return 5;
#elif defined(__aarch64__) || defined(__arm64__)
    register uint64_t* p __asm__("x9") = vgc_ir_regs;
    __asm__ __volatile__(
        "stp x19, x20, [%0, #0]\n\t"
        "stp x21, x22, [%0, #16]\n\t"
        "stp x23, x24, [%0, #32]\n\t"
        "stp x25, x26, [%0, #48]\n\t"
        "stp x27, x28, [%0, #64]\n\t"
        : : "r"(p) : "memory");
    return 10;
#else
    return 0;
#endif
}
static uint64_t vgc_ir_reg(int i) { return vgc_ir_regs[i]; }
// 1 when the page holding v is mapped by nothing (a mapping asked for there gets it)
static int vgc_ir_page_free(uint64_t v) {
    if (v < 0x10000 || v >= 0x800000000000ull) return 0;
    uintptr_t ps = (uintptr_t)getpagesize();
    uintptr_t pg = (uintptr_t)v & ~(ps - 1);
    void* q = mmap((void*)pg, ps, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (q == MAP_FAILED) return 0;
    munmap(q, ps);
    return (uintptr_t)q == pg;
}
