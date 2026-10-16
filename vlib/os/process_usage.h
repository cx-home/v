// cx-home/v#48: a reaped child's resource usage. Process reaped its child with
// waitpid, which drops the rusage the kernel hands to wait4 at that same reap;
// once the child is gone nothing can get it back (getrusage(RUSAGE_CHILDREN)
// sums every reaped child of the process). out[0] user ns, out[1] system ns,
// out[2] peak resident set in bytes.
#include <stdint.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#if !defined(__TINYC__)
#ifndef PSAPI_VERSION
#define PSAPI_VERSION 2 // GetProcessMemoryInfo = kernel32's K32GetProcessMemoryInfo, no -lpsapi
#endif
#include <psapi.h>
#endif
static void v_os_process_usage_win(void *h, int64_t *out) {
	FILETIME c, e, k, u;
	out[0] = 0;
	out[1] = 0;
	out[2] = 0;
	if (GetProcessTimes((HANDLE)h, &c, &e, &k, &u)) {
		// FILETIME counts 100 ns units
		out[0] = (int64_t)((((uint64_t)u.dwHighDateTime) << 32) | u.dwLowDateTime) * 100;
		out[1] = (int64_t)((((uint64_t)k.dwHighDateTime) << 32) | k.dwLowDateTime) * 100;
	}
#if !defined(__TINYC__)
	PROCESS_MEMORY_COUNTERS pmc;
	memset(&pmc, 0, sizeof(pmc));
	pmc.cb = sizeof(pmc);
	if (GetProcessMemoryInfo((HANDLE)h, &pmc, sizeof(pmc))) {
		out[2] = (int64_t)pmc.PeakWorkingSetSize;
	}
#endif
}
#else
#include <sys/types.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <sys/wait.h>
// waitpid with the reaped child's usage; out is written only when a child was reaped
static int v_os_wait4_usage(int pid, int *status, int options, int64_t *out) {
	struct rusage ru;
	memset(&ru, 0, sizeof(ru));
	int ret = wait4(pid, status, options, &ru);
	if (ret > 0) {
		out[0] = (int64_t)ru.ru_utime.tv_sec * 1000000000 + (int64_t)ru.ru_utime.tv_usec * 1000;
		out[1] = (int64_t)ru.ru_stime.tv_sec * 1000000000 + (int64_t)ru.ru_stime.tv_usec * 1000;
#if defined(__APPLE__)
		out[2] = (int64_t)ru.ru_maxrss; // bytes on darwin
#else
		out[2] = (int64_t)ru.ru_maxrss * 1024; // KiB elsewhere
#endif
	}
	return ret;
}
#endif
