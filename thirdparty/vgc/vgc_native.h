// vgc_native.h — the collector's ABI for native code linked into a vgc program
// (cx-private NATV-18, the fork side of the cx native linkage; cx-home/v#47).
//
// Native code here is C that is compiled outside V's cgen (cx's s2b emission of
// IR-covered defs, a C library, a callback trampoline) and linked with a V
// runtime built with `-gc e` / `-gc vgc`. V-generated C needs none of this:
// cgen emits the same barrier and registers its own threads.
//
// The four rules, each with the call that keeps it:
//
//  1. THREADS. The collector scans only registered threads. A V thread is
//     registered by its spawn wrapper; any other thread (pthread_create in
//     native code, a library's worker or callback thread) is invisible until it
//     allocates, so an object only it holds is freed under it. Such a thread
//     calls vgc_thread_attach() before it first touches a GC reference, and
//     vgc_thread_detach() (optional: thread exit does it) after its last.
//     Attach after the V runtime is up (main has started); never detach a
//     thread V started, and never detach inside a safe region.
//
//  2. FRAMES. On a registered thread every frame is scanned conservatively,
//     native frames included: [sp, stack base] plus the callee-saved registers
//     (captured at the cooperative park, the safe-region entry, or by the
//     suspend fallback). Native code needs no frame maps and no shadow stack.
//     What is NOT scanned: memory from malloc/mmap, another image's data
//     segment (a dlopen'ed library; the main image and everything linked into
//     it statically, libcx.a included, IS scanned), and alternate stacks
//     (makecontext/fibers). A GC reference parked there is pinned with
//     vgc_native_pin(p) and released with exactly one vgc_native_unpin(p).
//
//  3. STORES. A store of a GC reference INTO a GC-heap object (a field, an
//     array element, a map slot) is followed by vgc_native_wb_gate(obj), obj
//     being the address cgen passes for the same store: the struct pointer, or
//     the array's data pointer. Stores to locals, to the stack and to non-GC
//     memory need no barrier. Skipping it is unsound during a concurrent mark
//     and for a permanent-generation object (the reference is missed, the
//     object freed). The gate is one range test on two globals; it calls out
//     only while a concurrent mark runs or the target is in the permanent
//     generation.
//
//  4. BLOCKING. A native call that may block (I/O, a lock, a sleep) and holds
//     no GC reference it will store or carry out may run inside
//     vgc_native_safe_enter() / vgc_native_safe_exit(): the collector then
//     neither waits for nor suspends the thread. A non-blocking native loop
//     needs nothing: the stop's bounded park wait falls back to suspending it,
//     which is sound (only its pause share is longer).
//
// Allocation: pointer-holding objects come from the scanned allocator
// (malloc/vcalloc of the V runtime); a GC reference is never stored in a
// noscan (malloc_noscan) object.
//
// Link check: every unit that includes this header references
// vgc_native_abi_1, so a runtime without this ABI fails at link time, not at
// run time.
#ifndef VGC_NATIVE_H
#define VGC_NATIVE_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 1. threads: 1 = registered by this call, 0 = already registered.
int vgc_thread_attach(void);
void vgc_thread_detach(void);

// 2. roots outside the scanned ranges.
void vgc_native_pin(void* p);
void vgc_native_unpin(void* p);

// 3. the store barrier. The test is cgen's vgc_wb_gate (vlib/v/gen/c/cgen.v,
// held equal by vlib/v/gen/c/vgc_native_header_test.v): [vgc_wb_lo, +vgc_wb_len)
// is empty when no barrier is needed, the permanent generation's range once
// promoted, and the whole address space during a concurrent middle.
extern size_t vgc_wb_lo;
extern size_t vgc_wb_len;
void vgc_wb_store(void* obj);
static inline void vgc_native_wb_gate(void* p) { if (__builtin_expect((size_t)(uintptr_t)p - vgc_wb_lo < vgc_wb_len, 0)) vgc_wb_store(p); }

// 4. blocking regions: gc_safe_region_enter/exit under fixed exported names (a
// V pub fn is static in an object-file build of the runtime, _VOBJECTFILE).
void vgc_native_safe_enter(void);
void vgc_native_safe_exit(void);

// the link-time ABI check
int vgc_native_abi_1(void);
__attribute__((used)) static int (*const vgc__native_abi_ref)(void) = vgc_native_abi_1;

#ifdef __cplusplus
}
#endif
#endif
