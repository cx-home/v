import os

const vroot = os.dir(@VEXE)
const test_vexe = os.quoted_path(@VEXE)
const testdata_dir = os.join_path(vroot, 'vlib/v/gen/c/testdata/gc_e_nil_ref_field')

// cx-home/v#2 (root cause of cx-private#737): under `-gc e`, generated
// `<T>_free` fns called the pointee's free through reference fields
// UNCONDITIONALLY — a field still holding its `unsafe { nil }` default
// dereferenced NULL (SIGSEGV) whenever such a value was freed. The
// module-internal `v test` compilation of the testdata inserts exactly
// such a free (of the option-field unwrap copy at test scope exit).
// The fix guards every pointer-field free: `if (it->f != 0) { ... }`.
fn test_gc_e_nil_reference_field_free_is_guarded() {
	cmd := '${test_vexe} -cc cc -gc e test ${os.quoted_path(testdata_dir)}'
	res := os.execute(cmd)
	assert res.exit_code == 0, '${cmd}\n${res.output}'
}
