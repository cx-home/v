// vgc_native_header_test.v — NATV-18 (cx-home/v#47): the store gate native code
// calls (thirdparty/vgc/vgc_native.h, vgc_native_wb_gate) tests exactly what
// cgen's vgc_wb_gate tests, so a change to one without the other fails here
// rather than as a missed reference in a native unit.
import os

const vroot = os.dir(@VEXE)

const gate_test = '(size_t)(uintptr_t)p - vgc_wb_lo < vgc_wb_len'

fn test_cgen_gate_and_native_gate_test_the_same_range() {
	cgen := os.read_file(os.join_path(vroot, 'vlib', 'v', 'gen', 'c', 'cgen.v'))!
	hdr := os.read_file(os.join_path(vroot, 'thirdparty', 'vgc', 'vgc_native.h'))!
	cg := cgen.split_into_lines().filter(it.contains('static inline void vgc_wb_gate(void* p)'))
	ng :=
		hdr.split_into_lines().filter(it.contains('static inline void vgc_native_wb_gate(void* p)'))
	assert cg.len == 1
	assert ng.len == 1
	assert cg[0].contains(gate_test)
	assert ng[0].contains(gate_test)
	// the same body after the name
	assert cg[0].all_after('vgc_wb_gate(void* p)').trim_right("')") == ng[0].all_after('vgc_native_wb_gate(void* p)')
	// and the same globals
	assert cgen.contains("'extern size_t vgc_wb_lo; extern size_t vgc_wb_len;'")
	assert hdr.contains('extern size_t vgc_wb_lo;') && hdr.contains('extern size_t vgc_wb_len;')
}

// an object-file build of a -gc e program (`-o x.o`, the way a runtime is
// linked with separately compiled native code) declared vgc_wb_lo/vgc_wb_len
// `extern` in the headers and then defined them `static`: a C error.
fn test_a_gc_e_object_file_build_compiles() {
	dir := os.join_path(os.vtmp_dir(), 'vgc_native_obj_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	src := os.join_path(dir, 'o.v')
	os.write_file(src, 'fn main() {\n\tmut a := []string{}\n\ta << "x"\n\tprintln(a.len)\n}\n')!
	obj := os.join_path(dir, 'o.o')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -o ${os.quoted_path(obj)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	assert os.exists(obj)
}
