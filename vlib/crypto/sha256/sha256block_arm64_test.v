module sha256

// block() (the ARMv8 path where the compiler has it) and block_generic agree
// on every block count and on a chained state, so a digest never depends on
// which step ran.
fn test_block_matches_block_generic() {
	for nblocks in [1, 2, 3, 7, 16, 65] {
		mut data := []u8{len: nblocks * chunk}
		mut seed := u32(nblocks * 2654435761)
		for i in 0 .. data.len {
			seed = seed * 1103515245 + 12345
			data[i] = u8(seed >> 16)
		}
		mut a := new()
		mut b := new()
		block(mut a, data)
		block_generic(mut b, data)
		assert a.h == b.h, 'state after ${nblocks} blocks'
		// a second call continues from the chained state
		block(mut a, data[..chunk])
		block_generic(mut b, data[..chunk])
		assert a.h == b.h, 'chained state after ${nblocks}+1 blocks'
	}
}

fn test_a_partial_tail_is_left_to_the_caller() {
	data := []u8{len: chunk + 10, init: u8(index)}
	mut a := new()
	mut b := new()
	block(mut a, data)
	block_generic(mut b, data)
	assert a.h == b.h
}
