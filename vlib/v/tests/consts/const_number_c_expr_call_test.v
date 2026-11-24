// vtest vflags: -enable-globals
// cx-home/cx-core-code#268: a number const or global whose value V writes as a
// call — a shift (`v__lshift_*` / `v__rshift_*`), an integer `/` or `%`
// (`VSAFE_DIV_*` / `VSAFE_MOD_*`) — is not a C constant expression, so it is
// assigned in `_vinit`, not on its definition (cc: "initializer element is not
// a compile-time constant" on rand's reciprocal_2_23rd and core's fa_exact_max)
const shl_u32 = u32(1) << 23
const shr_u64 = u64(1024) >> 3
const recip_23 = f64(1.0) / f64(u32(1) << 23)
const exact_max = i64(1) << 53
const idiv = int(100) / 7
const imod = int(100) % 7
const plain = usize(64) * 1024

__global g_shl = u64(1) << 40
__global g_idiv = int(100) / 7

fn test_number_const_with_a_call_in_its_c_value() {
	assert shl_u32 == 8388608
	assert shr_u64 == 128
	assert recip_23 == 1.0 / 8388608.0
	assert exact_max == 9007199254740992
	assert idiv == 14
	assert imod == 2
	assert plain == 65536
}

fn test_number_global_with_a_call_in_its_c_value() {
	assert g_shl == u64(1099511627776)
	assert g_idiv == 14
}
