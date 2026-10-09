module runtime

import os

#include <sys/types.h>
#include <sys/sysctl.h>

// KinfoProcHead mirrors the leading fields of FreeBSD's struct kinfo_proc
// (<sys/user.h>) up to ki_rssize, on LP64 (amd64, arm64). The header itself
// is not included: tcc cannot parse what it pulls in (machine/segments.h:
// 'field width 64 not implemented'), which is why the tcc build used to fall
// back to getrusage's ru_maxrss — the PEAK resident set, which never falls.
// used_memory_freebsd_test.v checks every offset against the real header
// under cc.
struct KinfoProcHead {
	ki_structsize   i32
	ki_layout       i32
	ki_ptrs         [8]voidptr // ki_args, ki_paddr, ki_addr, ki_tracep, ki_textvp, ki_fd, ki_vmspace, ki_wchan
	ki_ids          [6]i32     // ki_pid, ki_ppid, ki_pgid, ki_tpgid, ki_sid, ki_tsid
	ki_jobc         i16
	ki_spare_short1 i16
	ki_tdev         u32     // ki_tdev_freebsd11
	ki_sigs         [16]u32 // ki_siglist, ki_sigmask, ki_sigignore, ki_sigcatch
	ki_creds        [5]u32  // ki_uid, ki_ruid, ki_svuid, ki_rgid, ki_svgid
	ki_ngroups      i16
	ki_spare_short2 i16
	ki_groups       [16]u32 // KI_NGROUPS
	ki_size         usize
	ki_rssize       i64
}

// used_memory retrieves the current physical memory usage of the process:
// ki_rssize (resident pages now) of this pid's kinfo_proc, through
// sysctl(KERN_PROC_PID), under every compiler (cx-home/v#17: the tcc build
// answered the peak, so vgc_large_drop_test on FreeBSD read 70340608 ->
// 70340608 while the collector trimmed 60 MB; no libprocstat either).
pub fn used_memory() !u64 {
	page_size := usize(C.sysconf(C._SC_PAGESIZE))
	c_errno_1 := C.errno
	if page_size == usize(-1) {
		return error('used_memory: C.sysconf() return error code = ${c_errno_1}')
	}
	mut mib := [C.CTL_KERN, C.KERN_PROC, C.KERN_PROC_PID, os.getpid()]!
	mut buf := [4096]u8{} // >= sizeof(struct kinfo_proc): 1088 on LP64
	mut len := usize(buf.len)
	if unsafe { C.sysctl(&mib[0], 4, &buf[0], &len, nil, 0) } == -1 {
		c_errno_2 := C.errno
		return error('used_memory: C.sysctl(KERN_PROC_PID) return error code = ${c_errno_2}')
	}
	head := unsafe { &KinfoProcHead(&buf[0]) }
	if len < sizeof(KinfoProcHead) || usize(head.ki_structsize) != len {
		return error('used_memory: unexpected kinfo_proc (${len} bytes, ki_structsize ${head.ki_structsize})')
	}
	return u64(head.ki_rssize) * u64(page_size)
}
