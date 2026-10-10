module runtime

// The KinfoProcHead mirror (used_memory_freebsd.c.v) against the real
// struct kinfo_proc. Only under cc: tcc cannot parse <sys/user.h>.
$if !tinyc {
	#include <sys/user.h>
}

struct C.kinfo_proc {
	ki_structsize i32
	ki_pid        i32
	ki_uid        u32
	ki_ngroups    i16
	ki_groups     [16]u32
	ki_size       usize
	ki_rssize     i64
}

fn test_kinfo_proc_head_matches_the_header() {
	$if !tinyc {
		assert sizeof(KinfoProcHead) <= sizeof(C.kinfo_proc)
		assert __offsetof(KinfoProcHead, ki_ids) == __offsetof(C.kinfo_proc, ki_pid)
		assert __offsetof(KinfoProcHead, ki_creds) == __offsetof(C.kinfo_proc, ki_uid)
		assert __offsetof(KinfoProcHead, ki_ngroups) == __offsetof(C.kinfo_proc, ki_ngroups)
		assert __offsetof(KinfoProcHead, ki_groups) == __offsetof(C.kinfo_proc, ki_groups)
		assert __offsetof(KinfoProcHead, ki_size) == __offsetof(C.kinfo_proc, ki_size)
		assert __offsetof(KinfoProcHead, ki_rssize) == __offsetof(C.kinfo_proc, ki_rssize)
	}
	assert used_memory()! > 0
}
