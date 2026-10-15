// vgc_native_unit.h — the entry points of vgc_native_unit.c for
// vgc_native_attach_test.v (NATV-18, cx-home/v#47).
#ifndef VGC_NATIVE_UNIT_H
#define VGC_NATIVE_UNIT_H
void vna_start(int mode);
void vna_hand(int i, void* p);
int vna_holding_n(void);
int vna_finish(void);
int vna_new_n(void);
int vna_again_n(void);
void vna_park(void* p);
int vna_parked_bad(int byte);
void vna_unpark(void);
void vna_gate(void* obj);
int vna_abi(void);
void vna_safe_roundtrip(void);
void vna_poll_start(int poll);
int vna_poll_finish(void);
int vna_poll_live_n(void);
int vna_poll_seen_so_far(void);
#endif
