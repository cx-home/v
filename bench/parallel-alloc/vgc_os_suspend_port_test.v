// vgc_os_suspend_port_test.v — every thread vgc registers on darwin, linux,
// freebsd and windows carries an OS suspend handle (cx-home/v#17, #20).
//
// The handle (caches[i].mach_port: the mach port on darwin, the kernel thread
// id on linux and freebsd, the thread id on windows) is what the stop-the-world waits for and suspends.
// A thread whose handle is 0 is skipped by both: the cooperative collector
// neither waits for it to park nor suspends it, and the -d vgc_concurrent
// collector's STW windows stop nothing at all. FreeBSD answered 0 for every
// thread (thirdparty/vgc/vgc_platform.h had no FreeBSD suspend path, only the
// "not yet ported" stub), and concurrent_mt_sound read bad records there
// (bad=7..818 on CI, every pin). The stub reproduces it on macOS: built with
// the darwin branch compiled out, mt_sound -d vgc_concurrent read bad=76 at
// T=8 and bad=445 at T=16; with the darwin branch, bad=0. Windows took the
// same stub (cx-home/v#20): mt_sound T=8 did not finish in 58 min there.
//
// Run: ./v test bench/parallel-alloc/vgc_os_suspend_port_test.v
module main

fn C.vgc_thread_self_port() u32
fn C.vgc_get_cache_idx() int

// cx-home/v#20: mingw gcc ignores __declspec(thread), so every thread read ONE
// cache index — a spawned thread never took a slot of its own.
fn cache_idx_of_a_new_thread() int {
	t := spawn fn () int {
		return C.vgc_get_cache_idx()
	}()
	return t.wait()
}

fn test_every_thread_has_its_own_vgc_slot() {
	$if vgc ? {
		main_idx := C.vgc_get_cache_idx()
		a := cache_idx_of_a_new_thread()
		b := cache_idx_of_a_new_thread()
		println('vgc_os_suspend_port: slots main=${main_idx} threads=${a},${b}')
		assert main_idx >= 0
		assert a >= 0 && b >= 0
		assert a != main_idx && b != main_idx, "a spawned thread shares the main thread's vgc slot: thread-local storage is not per-thread"
	}
}

fn port_of_a_new_thread() u32 {
	t := spawn fn () u32 {
		return C.vgc_thread_self_port()
	}()
	return t.wait()
}

fn test_every_registered_thread_has_an_os_suspend_handle() {
	// msvc builds default to no GC (vlib/v/pref/default.v): only a vgc build has the handle
	$if vgc ? {
		$if macos || linux || freebsd || windows {
			main_port := C.vgc_thread_self_port()
			a := port_of_a_new_thread()
			b := port_of_a_new_thread()
			println('vgc_os_suspend_port: main=${main_port} threads=${a},${b}')
			assert main_port != 0, 'the main thread has no OS suspend handle: the STW cannot stop it'
			assert a != 0 && b != 0, 'a spawned thread has no OS suspend handle: the STW cannot stop it'
			assert a != main_port && b != main_port
		}
	}
}
