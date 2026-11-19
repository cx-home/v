// vgc_vector_reg_root.h — the holder for vgc_vector_reg_root_test.v (cx-home/cx-core-code#282).
// vgc_vr_hold receives an object's address only in DISGUISED form (addr ^ mask), and in ONE asm block
// unmasks it into a vector register (x86-64 xmm7, arm64 v7), zeroes every general register that could
// still name it, says it has started, spins until *stop, and hands the address back out of the vector
// register. While it spins, the only word in the thread that names the object is that vector lane: a
// collector that does not scan a suspended thread's vector registers frees it.
#include <stdint.h>

static uint64_t vgc_vr_hold(uint64_t disguised, uint64_t mask, volatile int32_t* started, volatile int32_t* stop) {
#if defined(__x86_64__)
	uint64_t out = 0;
	volatile int32_t* st = started;
	volatile int32_t* sp = stop;
	__asm__ volatile(
		"movq %1, %%rax\n\t"
		"xorq %2, %%rax\n\t"
		"movq %%rax, %%xmm7\n\t"
		"xorl %%eax, %%eax\n\t"
		"xorl %%ecx, %%ecx\n\t" "xorl %%edx, %%edx\n\t" "xorl %%esi, %%esi\n\t" "xorl %%edi, %%edi\n\t"
		"xorl %%r8d, %%r8d\n\t" "xorl %%r9d, %%r9d\n\t" "xorl %%r10d, %%r10d\n\t" "xorl %%r11d, %%r11d\n\t"
		"xorl %%ebx, %%ebx\n\t" "xorl %%r12d, %%r12d\n\t" "xorl %%r13d, %%r13d\n\t" "xorl %%r14d, %%r14d\n\t" "xorl %%r15d, %%r15d\n\t"
		"movq %3, %%rcx\n\t"
		"movl $1, (%%rcx)\n\t"
		"movq %4, %%rcx\n\t"
		"1:\n\t"
		"pause\n\t"
		"movl (%%rcx), %%eax\n\t"
		"testl %%eax, %%eax\n\t"
		"jz 1b\n\t"
		"movq %%xmm7, %%rax\n\t"
		"movq %%rax, %0\n\t"
		: "=m"(out)
		: "m"(disguised), "m"(mask), "m"(st), "m"(sp)
		: "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "xmm7", "memory", "cc");
	return out;
#elif defined(__aarch64__) || defined(__arm64__)
	uint64_t out;
	__asm__ volatile(
		"ldr x9, %1\n\t"
		"ldr x10, %2\n\t"
		"eor x9, x9, x10\n\t"
		"fmov d7, x9\n\t"
		"mov x9, #0\n\t" "mov x10, #0\n\t"
		"mov w11, #1\n\t"
		"str w11, [%3]\n\t"
		"1:\n\t"
		"yield\n\t"
		"ldr w11, [%4]\n\t"
		"cbz w11, 1b\n\t"
		"fmov %0, d7\n\t"
		: "=&r"(out)
		: "m"(disguised), "m"(mask), "r"(started), "r"(stop)
		: "x9", "x10", "x11", "v7", "memory", "cc");
	return out;
#else
	*started = 1;
	while (*stop == 0) { }
	return disguised ^ mask;
#endif
}
