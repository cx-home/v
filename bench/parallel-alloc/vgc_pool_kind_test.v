// cx-platform-store#55 (the fourth issue): the pool answers "a span of this kind of n pages" without walking the
// pooled spans of another kind. With vgc_arena_of's scan gone, the store daemon's lock-holding thread at
// 1,000,000 documents (13-20 GB) still spent most of its samples in the pool's walks: vgc_pool_best_fit asked
// every populated size above a request for a span of the request's kind, and each ask walked that whole list.
// Drives the white-box self-check in module builtin (vgc_pool_kind_selftest).
//
//   ../../v -gc e test bench/parallel-alloc/vgc_pool_kind_test.v
module main

fn test_a_list_with_no_span_of_the_kind_is_not_walked() {
	rc, small_steps, plain_steps := vgc_pool_kind_selftest(1000)
	assert rc == 0, 'vgc_pool_kind_selftest check ${rc}'
	assert small_steps == 0, 'asking a list of 1,000 plain spans for a small one looked at ${small_steps} spans'
	assert plain_steps == 1, 'asking it for a plain one looked at ${plain_steps} spans'
}
