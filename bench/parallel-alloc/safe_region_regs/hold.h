// hold.h — the holder for vgc_safe_region_entry_frames_test.v (cx-home/v#88) (safe_region_regs/hold.v).
// vgc_srr_hold receives an object's address only DISGUISED (addr ^ mask) and, in ONE asm block,
// unmasks it into a callee-saved register (arm64 x19, x86-64 rbx), calls enter()
// (gc_safe_region_enter), then waits inside the region the way a blocking call does — a 4 KB
// frame written over the stack where enter's frames were, then a spin on g->done (g->entered = 1
// first) that touches no callee-saved register — calls leave() (gc_safe_region_exit), and hands
// the address back out of that register. That is a compiled caller keeping a heap pointer in a
// callee-saved register across a blocking call made inside a GC-safe region (a thread join): for
// the whole region the only word that names the object is the register's value as the caller
// sees it again after the region.
// With hold == 0 nothing is unmasked (the control: nothing names the object).
#include <stdint.h>

static uint64_t vgc_srr_hold(int hold, uint64_t disguised, uint64_t mask, void* g, void* enter,
	void* leave) {
	volatile uint64_t a[4] = {(uint64_t)enter, (uint64_t)leave, (uint64_t)g,
		hold ? (disguised ^ 0) : 0};
	volatile uint64_t m = hold ? mask : 0;
	(void)m;
#if (defined(__aarch64__) || defined(__arm64__)) && !defined(__TINYC__)
	uint64_t out;
	__asm__ volatile(
		"ldr x20, [%[a]]\n\t"
		"ldr x21, [%[a], #8]\n\t"
		"ldr x23, [%[a], #16]\n\t"
		"ldr x19, [%[a], #24]\n\t"
		"ldr x9, [%[m]]\n\t"
		"eor x19, x19, x9\n\t"
		"mov x9, #0\n\t"
		"blr x20\n\t"
		// the blocking call: a 4 KB frame written over where enter's frames were
		"sub sp, sp, #4096\n\t"
		"mov x9, sp\n\t"
		"add x10, sp, #4096\n\t"
		"1:\n\t"
		"str xzr, [x9], #8\n\t"
		"cmp x9, x10\n\t"
		"b.lo 1b\n\t"
		"mov w9, #1\n\t"
		"stlr w9, [x23]\n\t"
		"add x10, x23, #4\n\t"
		"2:\n\t"
		"yield\n\t"
		"ldar w9, [x10]\n\t"
		"cbz w9, 2b\n\t"
		"add sp, sp, #4096\n\t"
		"blr x21\n\t"
		"mov %[out], x19\n\t"
		: [out] "=r"(out)
		: [a] "r"(a), [m] "r"(&m)
		: "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13",
		  "x14", "x15", "x16", "x17", "x19", "x20", "x21", "x23", "x30", "v0", "v1", "v2", "v3",
		  "v4", "v5", "v6", "v7", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23", "v24",
		  "v25", "v26", "v27", "v28", "v29", "v30", "v31", "memory", "cc");
	return out;
#elif defined(__x86_64__) && !defined(_WIN32) && !defined(__TINYC__)
	uint64_t out = 0;
	__asm__ volatile(
		"movq %[a0], %%r12\n\t"
		"movq %[a1], %%r13\n\t"
		"movq %[a2], %%r14\n\t"
		"movq %[a3], %%rbx\n\t"
		"xorq %[m], %%rbx\n\t"
		"movq %%rsp, %%r15\n\t"
		"subq $256, %%rsp\n\t"
		"andq $-16, %%rsp\n\t"
		"xorl %%eax, %%eax\n\t"
		"call *%%r12\n\t"
		// the blocking call: a 4 KB frame written over where enter's frames were
		"subq $4096, %%rsp\n\t"
		"movq %%rsp, %%rcx\n\t"
		"leaq 4096(%%rsp), %%rdx\n\t"
		"1:\n\t"
		"movq $0, (%%rcx)\n\t"
		"addq $8, %%rcx\n\t"
		"cmpq %%rdx, %%rcx\n\t"
		"jb 1b\n\t"
		"movl $1, (%%r14)\n\t"
		"mfence\n\t"
		"2:\n\t"
		"pause\n\t"
		"movl 4(%%r14), %%eax\n\t"
		"testl %%eax, %%eax\n\t"
		"jz 2b\n\t"
		"addq $4096, %%rsp\n\t"
		"call *%%r13\n\t"
		"movq %%r15, %%rsp\n\t"
		"movq %%rbx, %[o]\n\t"
		: [o] "=m"(out)
		: [a0] "m"(a[0]), [a1] "m"(a[1]), [a2] "m"(a[2]), [a3] "m"(a[3]), [m] "m"(m)
		: "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14",
		  "r15", "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7", "xmm8", "xmm9",
		  "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15", "memory", "cc");
	return out;
#else
	// no callee-saved hold here: the test reports the platform as not covered
	((void (*)(void))enter)();
	volatile int32_t* entered = (volatile int32_t*)g;
	__atomic_store_n(entered, 1, __ATOMIC_SEQ_CST);
	while (__atomic_load_n(entered + 1, __ATOMIC_SEQ_CST) == 0) {
	}
	((void (*)(void))leave)();
	return 0;
#endif
}

// vgc_srr_covered: 1 where vgc_srr_hold holds the address in a callee-saved register
static int vgc_srr_covered(void) {
#if ((defined(__aarch64__) || defined(__arm64__)) || (defined(__x86_64__) && !defined(_WIN32))) && !defined(__TINYC__)
	return 1;
#else
	return 0;
#endif
}
