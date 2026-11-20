// vgc_shadow_stack_test.v — -d vgc_shadow_stack finds a thread's live
// references precisely and stops reading roots out of the bytes of live frames
// (cx-home/v#74, option (a): the shadow stack, after option (c)'s count failed
// on x86-64 with real=133).
//
// The default build scans every byte offset of a thread's stack (cx-home/v#60):
// clang can leave the only copy of a live pointer at an unaligned offset when it
// slices a V aggregate (the option unwrap's `byte data[]`, a struct with a
// leading byte). The price is prof-052's false roots: bytes of two neighbouring
// slots of a live cx eval frame spell an address inside a dropped object, which
// stays marked (cx-private#2062 reads 3 of 1,500). In the shadow-stack build the
// V aggregates that carry references live in a per-call frame record chained
// from a thread-local head (address-taken, so clang cannot slice them), the
// collector reads those records, and the machine stack and registers are read at
// aligned words only.
//
// Shape: ss/shadow.v (MODE=none / plant OFF=n / typed), stop-the-world cycles.
//   none        control: a dropped buffer is freed (the probe reads a free span).
//   plant OFF=0 an aligned word naming the buffer still keeps it (conservative
//               aligned scan of the machine stack stays).
//   plant OFF=1,3,7 RED on the byte scan: a word at an unaligned offset of a live
//               frame's byte array keeps the dropped buffer. The shadow build
//               must free it.
//   typed       #60's case in V types (a ?Node whose element array is the only
//               reference to a live buffer, held across two collections): kept,
//               all sevens, in both builds.
module main

import os

fn build() string {
	src := os.join_path(@DIR, 'ss', 'shadow.v')
	exe := os.join_path(os.vtmp_dir(), 'vgc_ss_shadow_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -prod -enable-globals -d vgc_shadow_stack -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn run(exe string, mode string, off int) (int, int) {
	r := os.execute('VGC_CM=0 MODE=${mode} OFF=${off} ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	lines := r.output.split_into_lines().filter(it.starts_with('ss mode='))
	assert lines.len == 1, r.output
	d := lines[0]
	println('vgc_shadow_stack ${d}')
	return d.all_after('kept=').all_before(' ').int(), d.all_after('sevens=').all_before(' ').int()
}

fn test_the_probe_reads_a_dropped_buffer_as_freed() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	k, _ := run(exe, 'none', 0)
	assert k == 0, 'a buffer nothing references was still in use after two collections'
	k0, _ := run(exe, 'plant', 0)
	assert k0 == 1, 'an aligned stack word naming the buffer did not keep it: the machine stack is still scanned at aligned words'
}

fn test_an_unaligned_word_of_a_live_frame_does_not_keep_a_dropped_object() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	for off in [1, 3, 7] {
		k, _ := run(exe, 'plant', off)
		assert k == 0, 'off ${off}: a word read across two slots of a live frame kept a dropped 64 KB buffer (prof-052\'s false root): the shadow build must not scan the machine stack at byte offsets'
	}
}

fn test_a_live_reference_in_a_v_aggregate_is_found_without_the_byte_scan() {
	exe := build()
	defer {
		os.rm(exe) or {}
	}
	_, sevens := run(exe, 'typed', 0)
	assert sevens == 64 * 1024, 'the ?Node\'s live buffer read ${sevens} sevens after two collections: the shadow frame must keep what the byte scan kept (cx-home/v#60)'
}
