module deflate

fn test_zlib_roundtrip() {
	data := 'Hello world!'.bytes()
	compressed := compress(data)!
	assert compressed[0] == 0x78 && compressed[1] == 0x9c // zlib header
	assert decompress(compressed)! == data
}

fn test_gzip_roundtrip() {
	data := 'Hello gzip!'.repeat(10).bytes()
	compressed := compress(data, format: .gzip)!
	assert compressed[0] == 0x1f && compressed[1] == 0x8b // gzip magic
	assert decompress(compressed)! == data
}

fn test_raw_deflate_roundtrip() {
	data := 'raw deflate'.repeat(20).bytes()
	raw := compress(data, format: .raw_deflate)!
	decoded := decompress(raw)! // auto-detected as raw
	assert decoded == data
}

fn test_decompress_auto_detects_all_formats() {
	data := 'multi-format detection test'.repeat(5).bytes()
	assert decompress(compress(data)!)! == data
	assert decompress(compress(data, format: .gzip)!)! == data
	assert decompress(compress(data, format: .raw_deflate)!)! == data
}

fn test_wrapper_helpers_match_unified_api() {
	data := 'wrapper compatibility'.repeat(8).bytes()
	assert compress(data)! == compress(data, format: .zlib)!
	assert compress_gzip(data)! == compress(data, format: .gzip)!
	assert compress_raw(data)! == compress(data, format: .raw_deflate)!
}

fn test_roundtrip_repeated() {
	data := 'abcabc'.repeat(100).bytes()
	compressed := compress(data)!
	assert compressed.len < data.len
	assert decompress(compressed)! == data
}

fn test_bad_compression_method_fails() {
	bad := [u8(0x79), 0x18, 0x00, 0x00, 0x00, 0x00]
	decompress(bad) or {
		assert err.msg().len > 0
		return
	}
	assert false
}

fn test_corrupt_checksum_fails() {
	mut enc := compress(('hello world').repeat(10).bytes())!
	// flip a byte in the adler32 footer
	enc[enc.len - 1] ^= 0xff
	decompress(enc) or {
		assert err.msg().contains('adler32')
		return
	}
	assert false
}

fn test_truncated_zlib_payload_fails() {
	decompress([u8(0x78), 0x9c, 0x03, 0x00, 0x00, 0x00, 0x01]) or {
		assert err.msg().contains('unexpected end of stream')
		return
	}
	assert false
}

fn test_zlib_inserted_bytes_before_adler_fails() {
	enc := compress('zlib injected trailer bytes'.repeat(4).bytes())!
	mut bad := []u8{cap: enc.len + 2}
	bad << enc[..enc.len - 4]
	bad << [u8(0xaa), 0x55]
	bad << enc[enc.len - 4..]
	decompress(bad) or {
		assert err.msg() == 'invalid zlib stream: trailing data before adler32'
		return
	}
	assert false
}

fn test_gzip_inserted_bytes_before_trailer_fails() {
	enc := compress('gzip injected trailer bytes'.repeat(4).bytes(), format: .gzip)!
	mut bad := []u8{cap: enc.len + 1}
	bad << enc[..enc.len - 8]
	bad << u8(0x42)
	bad << enc[enc.len - 8..]
	decompress(bad) or {
		assert err.msg() == 'invalid gzip stream: trailing data before trailer'
		return
	}
	assert false
}

// deflate_skewed_literals builds a payload the dynamic emitter is FOR:
// 2000 bytes over a 26-symbol alphabet with no long repeats, so LZ77
// finds almost nothing and the cost is all literals. Fixed Huffman spends
// 8 bits on every one of them; a dynamic table spends ~4.7. Deterministic
// (a plain LCG) so the sizes below are reproducible.
fn deflate_skewed_literals(n int) []u8 {
	mut data := []u8{cap: n}
	mut x := u32(1)
	for _ in 0 .. n {
		x = x * 1103515245 + 12345
		data << u8(97 + (x >> 16) % 26)
	}
	return data
}

// The dynamic-Huffman emitter must actually WIN where it is supposed to
// (cx-private#1095, Z-8.4). Both emitters run off the same token stream,
// so this pins their ORDER, not their bytes, and the round-trip proves
// the dynamic header decodes.
fn test_dynamic_block_beats_fixed_on_skewed_literals() {
	data := deflate_skewed_literals(2000)
	tokens := deflate_tokenize(data)
	mut wf := BitWriter{}
	wf.write_bits(1, 1)
	wf.write_bits(1, 2)
	emit_tokens(mut wf, tokens, fixed_litlen_codes, fixed_litlen_lens, fixed_dist_codes,
		fixed_dist_lens)
	wf.flush()
	mut wd := BitWriter{}
	emit_dynamic_block(mut wd, tokens)!
	eprintln('deflate emitters: raw=${data.len} fixed=${wf.buf.len} dynamic=${wd.buf.len}')
	assert wd.buf.len < wf.buf.len, 'dynamic (${wd.buf.len}) did not beat fixed (${wf.buf.len})'
	best := deflate_compress_best(data)!
	assert best.len == wd.buf.len, 'compress_best must take the dynamic block here'
	assert decompress_raw_with_consumed(best)!.decoded == data
}

// Fixed still wins on input too short to pay for a dynamic header — the
// smallest-of choice is a real choice, not a one-way switch.
fn test_fixed_block_wins_on_short_input() {
	data := 'hi'.bytes()
	best := deflate_compress_best(data)!
	tokens := deflate_tokenize(data)
	mut wf := BitWriter{}
	wf.write_bits(1, 1)
	wf.write_bits(1, 2)
	emit_tokens(mut wf, tokens, fixed_litlen_codes, fixed_litlen_lens, fixed_dist_codes,
		fixed_dist_lens)
	wf.flush()
	assert best.len == wf.buf.len, 'short input must keep the fixed block'
	assert decompress_raw_with_consumed(best)!.decoded == data
}
