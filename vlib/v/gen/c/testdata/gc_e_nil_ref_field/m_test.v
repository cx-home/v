module p5

fn test_field_unwrap() {
	res := parse('a---b')
	multi := res.multi or { panic('none') }
	assert multi.len == 2
}
