#ifndef V_PREALLOC_ATOMICS_H
#define V_PREALLOC_ATOMICS_H

#if defined(_MSC_VER)
#include <intrin.h>
static inline int v_prealloc_atomic_add_i32(int *ptr, int delta) {
	return (int)_InterlockedExchangeAdd((volatile long*)ptr, (long)delta) + delta;
}
static inline int v_prealloc_atomic_load_i32(int *ptr) {
	return (int)_InterlockedCompareExchange((volatile long*)ptr, 0, 0);
}
static inline int v_prealloc_atomic_store_i32(int *ptr, int val) {
	_InterlockedExchange((volatile long*)ptr, (long)val);
	return val;
}
static inline int v_prealloc_atomic_cas_i32(int *ptr, int expected, int desired) {
	return _InterlockedCompareExchange((volatile long*)ptr, (long)desired, (long)expected) == expected;
}
#elif defined(__TINYC__) && defined(__x86_64__)
// tcc on x86-64 has no __sync builtins and FreeBSD's tcc links nothing that
// defines them (cx-private#1856): the lock-prefixed instructions instead.
static inline int v_prealloc_atomic_add_i32(int *ptr, int delta) {
	int old = delta;
	__asm__ __volatile__("lock; xaddl %0, %1" : "+r"(old), "+m"(*ptr) : : "memory");
	return old + delta;
}
static inline int v_prealloc_atomic_load_i32(int *ptr) {
	return v_prealloc_atomic_add_i32(ptr, 0);
}
static inline int v_prealloc_atomic_store_i32(int *ptr, int val) {
	int old = val;
	__asm__ __volatile__("xchgl %0, %1" : "+r"(old), "+m"(*ptr) : : "memory");
	return old;
}
static inline int v_prealloc_atomic_cas_i32(int *ptr, int expected, int desired) {
	int prev;
	__asm__ __volatile__("lock; cmpxchgl %2, %1" : "=a"(prev), "+m"(*ptr) : "r"(desired), "0"(expected) : "memory");
	return prev == expected;
}
#else
static inline int v_prealloc_atomic_add_i32(int *ptr, int delta) {
	return __sync_add_and_fetch(ptr, delta);
}
static inline int v_prealloc_atomic_load_i32(int *ptr) {
	return __sync_add_and_fetch(ptr, 0);
}
static inline int v_prealloc_atomic_store_i32(int *ptr, int val) {
	return __sync_lock_test_and_set(ptr, val);
}
static inline int v_prealloc_atomic_cas_i32(int *ptr, int expected, int desired) {
	return __sync_bool_compare_and_swap(ptr, expected, desired);
}
#endif

#endif
