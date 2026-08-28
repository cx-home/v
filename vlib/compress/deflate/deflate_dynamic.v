module deflate

import hash.huffman

// deflate_dynamic.v — dynamic-Huffman DEFLATE emission (RFC 1951 §3.2.7).
//
// The fixed-Huffman emitter (deflate_compress.v) is correct everywhere but
// leaves ratio on the table for skewed symbol distributions (most text).
// This file adds the dynamic-block emitter over the SAME LZ77 tokenizer:
// tokenize once, emit both a fixed and a dynamic block from the tokens,
// return the smaller — a deterministic pure function of the input
// (cx-private #1095 / RULED: Z-8.4; upstreamable, CX-agnostic).

// DeflateToken is one LZ77 output symbol: a literal (sym < 257, the byte
// value) or a length/distance pair (sym is the RFC 1951 length symbol
// 257..285 plus its extra bits; dsym/dext the distance symbol + extras).
struct DeflateToken {
	sym       u16
	lext      u16
	lext_bits u8
	dsym      u8
	dext      u16
	dext_bits u8
}

// deflate_tokenize runs the LZ77 pass (greedy, hash-chained — the exact
// walk deflate_compress_fixed interleaves with emission) and returns the
// token stream, without the terminating end-of-block symbol.
@[direct_array_access]
fn deflate_tokenize(data []u8) []DeflateToken {
	mut tokens := []DeflateToken{cap: data.len / 3 + 16}
	if data.len == 0 {
		return tokens
	}
	mut last := []int{len: deflate_hash_size, init: -1}
	defer {
		unsafe { last.free() }
	}
	mut prev := []int{len: data.len, init: -1}
	defer {
		unsafe { prev.free() }
	}
	mut pos := 0
	for pos < data.len {
		off, match_len := find_lz_match(data, pos, last, prev)
		if match_len >= deflate_min_match {
			li, lext, lext_bits := length_code_info(match_len)
			di, dext, dext_bits := dist_code_info(off)
			tokens << DeflateToken{
				sym:       u16(257 + li)
				lext:      u16(lext)
				lext_bits: u8(lext_bits)
				dsym:      u8(di)
				dext:      u16(dext)
				dext_bits: u8(dext_bits)
			}
			for i in pos .. pos + match_len {
				if i + deflate_min_match < data.len {
					h := hash3(data, i)
					prev[i] = last[h]
					last[h] = i
				}
			}
			pos += match_len
		} else {
			tokens << DeflateToken{
				sym: u16(data[pos])
			}
			if pos + deflate_min_match < data.len {
				h := hash3(data, pos)
				prev[pos] = last[h]
				last[h] = pos
			}
			pos++
		}
	}
	return tokens
}

// emit_tokens writes the token stream plus the end-of-block symbol using
// the supplied litlen/dist code tables.
@[direct_array_access]
fn emit_tokens(mut w BitWriter, tokens []DeflateToken, ll_codes []u32, ll_lens []int,
	d_codes []u32, d_lens []int) {
	for t in tokens {
		w.write_bits(ll_codes[t.sym], ll_lens[t.sym])
		if t.sym >= 257 {
			w.write_bits(u32(t.lext), int(t.lext_bits))
			w.write_bits(d_codes[t.dsym], d_lens[t.dsym])
			w.write_bits(u32(t.dext), int(t.dext_bits))
		}
	}
	w.write_bits(ll_codes[256], ll_lens[256])
}

// huff_lengths_from_freqs computes length-limited canonical Huffman code
// lengths from symbol frequencies (the zlib bl_count overflow repair).
// Deterministic: every tie breaks on the smaller symbol index. A single
// used symbol gets length 1 (DEFLATE's allowed incomplete code).
fn huff_lengths_from_freqs(freqs []int, max_bits int) []int {
	n := freqs.len
	mut lengths := []int{len: n}
	mut used := []int{cap: n}
	for s, f in freqs {
		if f > 0 {
			used << s
		}
	}
	if used.len == 0 {
		return lengths
	}
	if used.len == 1 {
		lengths[used[0]] = 1
		return lengths
	}
	// Huffman tree via two sorted queues. Leaves ascend by (freq, sym);
	// internal nodes are created in nondecreasing weight order, so both
	// queues stay sorted and the two global minima sit at the two fronts.
	mut leaves := used.clone()
	leaves.sort_with_compare(fn [freqs] (a &int, b &int) int {
		if freqs[*a] != freqs[*b] {
			return freqs[*a] - freqs[*b]
		}
		return *a - *b
	})
	total := 2 * used.len - 1
	mut weight := []i64{len: total}
	mut parent := []int{len: total, init: -1}
	// nodes 0..used.len-1 are the leaves in `leaves` order
	for i, s in leaves {
		weight[i] = i64(freqs[s])
	}
	mut lq := 0            // next unconsumed leaf (leaves: [0, used.len))
	mut iq := used.len     // next unconsumed internal node ([used.len, next))
	mut next := used.len   // next internal node index to create
	for next < total {
		// pop the two smallest; a leaf wins weight ties (deterministic,
		// and it keeps depths minimal for equal weights).
		mut a := 0
		if lq < used.len && (iq >= next || weight[lq] <= weight[iq]) {
			a = lq
			lq++
		} else {
			a = iq
			iq++
		}
		mut b := 0
		if lq < used.len && (iq >= next || weight[lq] <= weight[iq]) {
			b = lq
			lq++
		} else {
			b = iq
			iq++
		}
		weight[next] = weight[a] + weight[b]
		parent[a] = next
		parent[b] = next
		next++
	}
	// depth per leaf, clamped to max_bits; count the overflow.
	mut bl_count := []int{len: max_bits + 1}
	mut overflow := 0
	for i in 0 .. used.len {
		mut d := 0
		mut p := parent[i]
		for p != -1 {
			d++
			p = parent[p]
		}
		if d > max_bits {
			overflow++
			d = max_bits
		}
		if d == 0 {
			d = 1
		}
		bl_count[d]++
	}
	// zlib repair: for each clamped code, move a shorter code down one
	// level (freeing code space) until the Kraft inequality holds again.
	for overflow > 0 {
		mut bits := max_bits - 1
		for bl_count[bits] == 0 {
			bits--
		}
		bl_count[bits]--
		bl_count[bits + 1] += 2
		bl_count[max_bits]--
		overflow -= 2
	}
	// Assign lengths canonically: most frequent symbols get the shortest
	// codes; ties break on symbol index (determinism).
	mut order := used.clone()
	order.sort_with_compare(fn [freqs] (a &int, b &int) int {
		if freqs[*a] != freqs[*b] {
			return freqs[*b] - freqs[*a]
		}
		return *a - *b
	})
	mut oi := 0
	for bits in 1 .. max_bits + 1 {
		for _ in 0 .. bl_count[bits] {
			// bl_count hands out shortest first; order[] is most-frequent
			// first — walk both in lockstep.
			lengths[order[oi]] = bits
			oi++
		}
	}
	return lengths
}

// cl_symbol_order is the RFC 1951 §3.2.7 transmission order of the
// code-length-code lengths.
const cl_symbol_order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

// ClToken is one RLE-encoded code-length symbol (0..18 + extra bits).
struct ClToken {
	sym       u8
	extra     u16
	extra_bits u8
}

// rle_code_lengths encodes the concatenated litlen+dist code-length array
// with the 16/17/18 run symbols (RFC 1951 §3.2.7).
fn rle_code_lengths(lens []int) []ClToken {
	mut out := []ClToken{cap: lens.len}
	mut i := 0
	for i < lens.len {
		l := lens[i]
		mut run := 1
		for i + run < lens.len && lens[i + run] == l {
			run++
		}
		if l == 0 {
			mut left := run
			for left >= 11 {
				take := if left > 138 { 138 } else { left }
				out << ClToken{ sym: 18, extra: u16(take - 11), extra_bits: 7 }
				left -= take
			}
			if left >= 3 {
				out << ClToken{ sym: 17, extra: u16(left - 3), extra_bits: 3 }
				left = 0
			}
			for _ in 0 .. left {
				out << ClToken{ sym: 0 }
			}
		} else {
			out << ClToken{ sym: u8(l) }
			mut left := run - 1
			for left >= 3 {
				take := if left > 6 { 6 } else { left }
				out << ClToken{ sym: 16, extra: u16(take - 3), extra_bits: 2 }
				left -= take
			}
			for _ in 0 .. left {
				out << ClToken{ sym: u8(l) }
			}
		}
		i += run
	}
	return out
}

// emit_dynamic_block writes one BFINAL dynamic-Huffman block containing
// `tokens`. Errors only if a built code table is invalid (a bug, surfaced
// rather than swallowed).
fn emit_dynamic_block(mut w BitWriter, tokens []DeflateToken) ! {
	// Symbol frequencies (the end-of-block symbol is always used).
	mut ll_freq := []int{len: 286}
	mut d_freq := []int{len: 30}
	ll_freq[256] = 1
	for t in tokens {
		ll_freq[t.sym]++
		if t.sym >= 257 {
			d_freq[t.dsym]++
		}
	}
	ll_lens := huff_lengths_from_freqs(ll_freq, 15)
	mut d_lens := huff_lengths_from_freqs(d_freq, 15)
	// RFC 1951: at least one distance code is transmitted even when the
	// block has no matches (zlib emits a single length-1 code).
	mut d_any := false
	for l in d_lens {
		if l > 0 {
			d_any = true
			break
		}
	}
	if !d_any {
		d_lens[0] = 1
	}
	mut hlit := 286
	for hlit > 257 && ll_lens[hlit - 1] == 0 {
		hlit--
	}
	mut hdist := 30
	for hdist > 1 && d_lens[hdist - 1] == 0 {
		hdist--
	}
	// Code-length-code over the RLE of both length arrays.
	mut combined := []int{cap: hlit + hdist}
	combined << ll_lens[..hlit]
	combined << d_lens[..hdist]
	cl_tokens := rle_code_lengths(combined)
	mut cl_freq := []int{len: 19}
	for t in cl_tokens {
		cl_freq[t.sym]++
	}
	cl_lens := huff_lengths_from_freqs(cl_freq, 7)
	mut hclen := 19
	for hclen > 4 && cl_lens[cl_symbol_order[hclen - 1]] == 0 {
		hclen--
	}
	ll_table := huffman.build(lengths: ll_lens, max_bits: 15, bit_order: .lsb_first)!
	d_table := huffman.build(lengths: d_lens, max_bits: 15, bit_order: .lsb_first)!
	cl_table := huffman.build(lengths: cl_lens, max_bits: 7, bit_order: .lsb_first)!
	// BFINAL=1, BTYPE=10 (dynamic)
	w.write_bits(1, 1)
	w.write_bits(2, 2)
	w.write_bits(u32(hlit - 257), 5)
	w.write_bits(u32(hdist - 1), 5)
	w.write_bits(u32(hclen - 4), 4)
	for k in 0 .. hclen {
		w.write_bits(u32(cl_lens[cl_symbol_order[k]]), 3)
	}
	for t in cl_tokens {
		w.write_bits(cl_table.codes[t.sym], cl_lens[t.sym])
		if t.extra_bits > 0 {
			w.write_bits(u32(t.extra), int(t.extra_bits))
		}
	}
	emit_tokens(mut w, tokens, ll_table.codes, ll_lens, d_table.codes, d_lens)
	w.flush()
}

// deflate_compress_best emits both a fixed and a dynamic block from ONE
// tokenize pass and returns the smaller — deterministic per input.
fn deflate_compress_best(data []u8) ![]u8 {
	if data.len == 0 {
		return deflate_compress_fixed(data)!
	}
	tokens := deflate_tokenize(data)
	// fixed emission from the same tokens
	mut wf := BitWriter{}
	wf.write_bits(1, 1)
	wf.write_bits(1, 2)
	emit_tokens(mut wf, tokens, fixed_litlen_codes, fixed_litlen_lens, fixed_dist_codes,
		fixed_dist_lens)
	wf.flush()
	mut wd := BitWriter{}
	emit_dynamic_block(mut wd, tokens) or {
		// A table-build failure is a bug; fail safe to the fixed block.
		return wf.buf
	}
	if wd.buf.len < wf.buf.len {
		return wd.buf
	}
	return wf.buf
}
