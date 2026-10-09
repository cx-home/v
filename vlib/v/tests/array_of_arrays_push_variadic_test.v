// cx-home/v#10: a variadic parameter pushed onto an array of arrays is ONE
// element; it was emitted as a push-many, reading its strings as arrays.
fn push_each(mut all [][]string, prefixes ...string) {
	all << prefixes.clone()
	all << prefixes
}

fn append_flat(mut flat []string, prefixes ...string) {
	flat << prefixes
	flat << prefixes.clone()
}

fn test_variadic_pushed_onto_array_of_arrays_is_one_element() {
	mut all := [][]string{}
	push_each(mut all, 'store', 'x')
	push_each(mut all, 'net')
	assert all == [['store', 'x'], ['store', 'x'], ['net'], ['net']]
}

fn test_variadic_pushed_onto_flat_array_appends_its_elements() {
	mut flat := []string{}
	append_flat(mut flat, 'a', 'b')
	assert flat == ['a', 'b', 'a', 'b']
}
