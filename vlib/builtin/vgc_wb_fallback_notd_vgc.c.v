module builtin

// vgc_wb_store is the concurrent-mark write barrier of the `-gc e` (vgc) backend.
// Its real definition lives in vgc_gc_d_vgc.c.v, which is only compiled when the
// `vgc` define is set (i.e. under `-gc e`). The call sites in array.v and map.v
// are wrapped in `$if vgc_concurrent ? { ... }`, so they emit no code in ordinary
// builds — but the checker still walks those comptime branches, and `v -os cross`
// emits every branch into the generated v.c. Both paths therefore need the symbol
// to resolve in non-vgc builds (boehm/none/...), where this no-op stands in.
// Only V code calls it here (the C barrier of assign.v is emitted under vgc
// alone), so it is kept by @[markused] under its V name: an @[export] made a
// public `vgc_wb_store` in every -is_o object, and two of them linked together
// were a duplicate symbol (vlib/v/gen/c/link_generated_c_files_test.v,
// cx-private#1894).
@[markused]
fn vgc_wb_store(obj voidptr) {
}
