module runtime

import os

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>

struct C.kinfo_proc {
	ki_rssize i64
}

// used_memory retrieves the current physical memory usage of the process.
// It reads the process's kinfo_proc through sysctl(KERN_PROC_PID) — the
// resident set NOW (ki_rssize, in pages). Every compiler takes this path: the
// tcc build used to answer getrusage's ru_maxrss, the PEAK resident set, which
// never falls, so a memory return read as nothing returned (cx-home/v#17:
// vgc_large_drop_test on FreeBSD read 70340608 -> 70340608 with the collector
// trimming 60 MB), and the cc build linked libprocstat for the same field.
pub fn used_memory() !u64 {
	page_size := usize(C.sysconf(C._SC_PAGESIZE))
	c_errno_1 := C.errno
	if page_size == usize(-1) {
		return error('used_memory: C.sysconf() return error code = ${c_errno_1}')
	}
	mut mib := [C.CTL_KERN, C.KERN_PROC, C.KERN_PROC_PID, os.getpid()]!
	mut kp := C.kinfo_proc{}
	mut len := usize(sizeof(C.kinfo_proc))
	if unsafe { C.sysctl(&mib[0], 4, &kp, &len, nil, 0) } == -1 {
		c_errno_2 := C.errno
		return error('used_memory: C.sysctl(KERN_PROC_PID) return error code = ${c_errno_2}')
	}
	if len < sizeof(C.kinfo_proc) {
		return error('used_memory: C.sysctl(KERN_PROC_PID) returned ${len} bytes')
	}
	return u64(kp.ki_rssize) * u64(page_size)
}
