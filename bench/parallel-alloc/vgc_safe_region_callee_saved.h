// vgc_safe_region_callee_saved.h — the C half of
// vgc_safe_region_callee_saved_test.v (cx-private#2079).
#include <stdint.h>

void builtin__gc_safe_region_enter(void);
void builtin__gc_safe_region_exit(void);
uint8_t* builtin__malloc_noscan(intptr_t n);

enum { srcs_words = 512 };
static const uint64_t srcs_canary = 0x9e3779b97f4a7c15ull;

// a fresh heap block filled with the canary; its address is answered in x0 and
// held nowhere else once the caller moves it
__attribute__((noinline)) static uintptr_t srcs_block(void) {
	uint64_t* p = (uint64_t*)builtin__malloc_noscan((intptr_t)(srcs_words * 8));
	for (int i = 0; i < srcs_words; i++) {
		p[i] = srcs_canary + (uint64_t)i;
	}
	return (uintptr_t)p;
}

// the blocking call's frames: they open on the stack the safe-region entry's
// frames just left (pthread_join's, a channel wait's) and overwrite it — here
// 4 KB under the stack pointer zeroed with scratch registers only, so nothing
// saves a callee-saved register on the way
#if defined(__aarch64__)
#define SRCS_BLOCK_CALL() __asm__ volatile( \
	"mov x9, sp\n\tsub x10, x9, #4096\n" \
	"1:\n\tstp xzr, xzr, [x10]\n\tadd x10, x10, #16\n\tcmp x10, x9\n\tb.lo 1b\n" \
	::: "x9", "x10", "memory", "cc")
#elif defined(__x86_64__)
#define SRCS_BLOCK_CALL() __asm__ volatile( \
	"lea -4096(%%rsp), %%rcx\n" \
	"1:\n\tmovq $0, (%%rcx)\n\tadd $8, %%rcx\n\tcmp %%rsp, %%rcx\n\tjb 1b\n" \
	::: "rcx", "memory", "cc")
#else
#define SRCS_BLOCK_CALL() do {} while (0)
#endif

// srcs_hold allocates the block and keeps its only reference in a callee-saved
// register (x19 / rbx) across a safe region whose blocking call overwrites the
// entry's dead frames, while another thread collects (go set, then wait for
// done). Answers the address.
__attribute__((noinline)) static uintptr_t srcs_hold(volatile uint32_t* go, volatile uint32_t* done) {
#if defined(__aarch64__)
	register uintptr_t keep __asm__("x19") = srcs_block();
#elif defined(__x86_64__)
	register uintptr_t keep __asm__("rbx") = srcs_block();
#else
	uintptr_t keep = srcs_block();
#endif
	__asm__ volatile("" : "+r"(keep));
	builtin__gc_safe_region_enter();
	__asm__ volatile("" : "+r"(keep));
	SRCS_BLOCK_CALL();
	__asm__ volatile("" : "+r"(keep));
	__atomic_store_n(go, 1, __ATOMIC_SEQ_CST);
	while (__atomic_load_n(done, __ATOMIC_SEQ_CST) == 0) {
		__asm__ volatile("" : "+r"(keep));
	}
	builtin__gc_safe_region_exit();
	__asm__ volatile("" : "+r"(keep));
	return keep;
}

static int srcs_intact(uintptr_t a) {
	const uint64_t* p = (const uint64_t*)a;
	for (int i = 0; i < srcs_words; i++) {
		if (p[i] != srcs_canary + (uint64_t)i) {
			return 0;
		}
	}
	return 1;
}
