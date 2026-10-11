// vgc_vinit_window_test.v — a module initialiser's objects stay in the
// collector's world (cx-home/v#27: the webhook-saga door on fix/fable-v116).
//
// V's _vinit zero-assigns the vgc_heap global AFTER builtin's HEAP consts
// registered the main thread (the heap-init ordering quirk; vgc_init runs
// after _vinit). The arena table, the span registry and — until cx-home/v#27 —
// the per-thread slot table all sat inside vgc_heap, so the zeroing wiped
// main's cache with the rest and main refilled from the re-created arena.
// With the slot table in C-side chunks, main's slot survived the zeroing with
// its spans — spans of the WIPED arena — and every object a module's init()
// carved from them was outside the collector's world: a pointer to it shades
// nothing, it is never scanned, and what is reachable only through it (a
// registry map's grown backing, a cache entry) is swept while live. The door
// refused every request with E_NO_CALLABLE after its first cycles.
//
// vinit_window/vinit.v is the fixture: cells of the HEAP consts' size classes
// allocated in fn init(), each the only path to a holder whose map and array
// grow in main; after two forced collections every holder's backing must still
// be allocated and intact. Red on 3dbdf70a4 (the 24-byte cell: its holder's
// map backing freed, 40,000 bad reads), green once vgc_ensure_registered
// re-registers a thread whose slot index the wiped table does not know.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_vinit_window_test.v
module main

import os

fn test_module_init_objects_survive_collections() {
	src := os.join_path(@DIR, 'vinit_window', 'vinit.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_vinit_window_${os.getpid()}')
	defer {
		os.rm(exe) or {}
	}
	// -d cx_envcheck: vgc_map_backing_status reports the backings' alloc bits
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -d cx_envcheck -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	run := os.execute(os.quoted_path(exe))
	assert run.exit_code == 0, 'exit ${run.exit_code}: ${run.output}'
	assert run.output.contains(' ok '), run.output
	println(run.output.trim_space())
}
