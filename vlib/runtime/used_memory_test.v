import runtime

fn test_used_memory() {
	used1 := runtime.used_memory()!
	println('used memory 1 : ${used1}')

	mut mem1 := unsafe { malloc(8 * 1024 * 1024) }
	unsafe { vmemset(mem1, 1, 8 * 1024 * 1024) }
	used2 := runtime.used_memory()!
	println('used memory 2 : ${used2}')

	mut mem2 := unsafe { malloc(64 * 1024 * 1024) }
	unsafe { vmemset(mem2, 1, 64 * 1024 * 1024) }
	used3 := runtime.used_memory()!
	println('used memory 3 : ${used3}')

	assert used1 > 0
	assert used2 >= used1
	assert used3 > used2
	unsafe {
		println(*&u8(mem1 + 1024))
		println(*&u8(mem2 + 1024))
	}
}

// used_memory is the resident set NOW, not its peak: pages handed back to the
// OS leave it (cx-home/v#17 — FreeBSD's tcc build answered ru_maxrss, so a
// collector's memory return never showed).
fn test_used_memory_falls_when_pages_are_returned() {
	$if linux || macos || freebsd {
		n := usize(64 * 1024 * 1024)
		p :=
			C.mmap(unsafe { nil }, n, C.PROT_READ | C.PROT_WRITE, C.MAP_PRIVATE | C.MAP_ANON, -1, 0)
		assert p != voidptr(-1)
		for i := usize(0); i < n; i += 4096 {
			unsafe {
				*(&u8(p) + i) = 1
			}
		}
		touched := runtime.used_memory()!
		assert C.munmap(p, n) == 0
		after := runtime.used_memory()!
		println('used memory touched 64 MB: ${touched}, after munmap: ${after}')
		assert after + n / 2 < touched
	}
}
