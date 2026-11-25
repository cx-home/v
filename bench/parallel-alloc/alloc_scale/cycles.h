// cycles.h — scale.v's C side (cx-private#2040): this process's CPU cycles and
// instructions so far (proc_pid_rusage RUSAGE_INFO_V4; every thread, the
// collector's too), 0 where the counters are not kept.
#include <stdint.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <libproc.h>
#include <sys/resource.h>
static uint64_t vgc_as_cycles(void) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
    return ri.ri_cycles;
}
static uint64_t vgc_as_instructions(void) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
    return ri.ri_instructions;
}
#else
static uint64_t vgc_as_cycles(void) { return 0; }
static uint64_t vgc_as_instructions(void) { return 0; }
#endif
