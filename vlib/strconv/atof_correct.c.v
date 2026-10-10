module strconv

import math.bits

// Correctly rounded decimal -> f64 (cx-home/v#25): the f64 nearest to the decimal
// literal, ties to even (IEEE 754 round-to-nearest), as Python's float(), C's strtod
// and Go's strconv.ParseFloat answer. Three steps, the first that is sure wins:
//   1. Clinger's exact fast path: <= 2^53 mantissa and |10^e| exact in f64;
//   2. Eisel-Lemire: a 128-bit product with the truncated power of ten; it reports
//      the cases its approximation cannot decide;
//   3. the arbitrary-precision decimal (800 digits) shifted by powers of two.
// The algorithm is the one Go's strconv (atof.go, eisel_lemire.go, decimal.go;
// BSD-style licence, Copyright The Go Authors) and Rust's core use.

const max_mant_digits = 19

const max_exp10_read = 10_000_000

const float64_pow10 = [f64(1e0), 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12,
	1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22]!

// FloatScan is a decimal literal read by scan_float.
struct FloatScan {
mut:
	mantissa u64  // the first max_mant_digits significant digits
	exp10    int  // value ~= mantissa * 10^exp10 (exact when !trunc)
	neg      bool // a leading '-'
	trunc    bool // a nonzero digit after the max_mant_digits-th was dropped
	start    int  // s[start..end] holds the digits, the '.', the exponent
	end      int  // the index after the literal (the parser's stop index)
}

// scan_float reads the literal with the grammar `parser` accepts: spaces, an optional
// '-', an optional '+', digits, an optional '.' and digits, an optional e/E with an
// optional sign and digits.
@[direct_array_access]
fn scan_float(s string) FloatScan {
	mut r := FloatScan{}
	mut i := 0
	for i < s.len && s[i].is_space() {
		i++
	}
	if i < s.len && s[i] == `-` {
		r.neg = true
		i++
	}
	if i < s.len && s[i] == `+` {
		i++
	}
	r.start = i
	mut nd := 0 // significant digits seen
	mut nd_mant := 0 // digits in r.mantissa
	mut dp := 0 // decimal point position relative to the significant digits
	for i < s.len && s[i] >= `0` && s[i] <= `9` {
		c := s[i]
		i++
		if c == `0` && nd == 0 {
			continue
		}
		nd++
		if nd_mant < max_mant_digits {
			r.mantissa = r.mantissa * 10 + u64(c - `0`)
			nd_mant++
		} else if c != `0` {
			r.trunc = true
		}
	}
	dp = nd
	if i < s.len && s[i] == `.` {
		i++
		for i < s.len && s[i] >= `0` && s[i] <= `9` {
			c := s[i]
			i++
			if c == `0` && nd == 0 {
				dp--
				continue
			}
			nd++
			if nd_mant < max_mant_digits {
				r.mantissa = r.mantissa * 10 + u64(c - `0`)
				nd_mant++
			} else if c != `0` {
				r.trunc = true
			}
		}
	}
	if i < s.len && (s[i] == `e` || s[i] == `E`) {
		i++
		mut esign := 1
		if i < s.len {
			if s[i] == `+` {
				i++
			} else if s[i] == `-` {
				esign = -1
				i++
			}
		}
		mut e := 0
		for i < s.len && s[i] >= `0` && s[i] <= `9` {
			if e < max_exp10_read {
				e = e * 10 + int(s[i] - `0`)
			}
			i++
		}
		dp += e * esign
	}
	r.end = i
	if r.mantissa != 0 {
		r.exp10 = dp - nd_mant
	}
	return r
}

// atof64_exact is Clinger's fast path: the mantissa and the power of ten are both
// exact f64 values, so one IEEE multiply or divide rounds once, correctly.
fn atof64_exact(mantissa u64, exp10 int, neg bool) (f64, bool) {
	if mantissa >> 52 != 0 {
		return 0, false
	}
	mut f := f64(mantissa)
	if neg {
		f = -f
	}
	if exp10 == 0 {
		return f, true
	}
	if exp10 > 0 && exp10 <= 15 + 22 {
		mut e := exp10
		// a big exponent with few digits moves zeros into the integer part
		if e > 22 {
			f *= float64_pow10[e - 22]
			e = 22
		}
		if f > 1e15 || f < -1e15 {
			return 0, false
		}
		return f * float64_pow10[e], true
	}
	if exp10 < 0 && exp10 >= -22 {
		return f / float64_pow10[-exp10], true
	}
	return 0, false
}

// eisel_lemire64 answers the bits of mantissa * 10^exp10 rounded to nearest-even, or
// false when its 128-bit approximation cannot decide (then the decimal path does).
fn eisel_lemire64(mantissa u64, exp10 int, neg bool) (u64, bool) {
	if mantissa == 0 {
		return if neg { double_minus_zero } else { double_plus_zero }, true
	}
	if exp10 < eisel_lemire_min_exp10 || exp10 > eisel_lemire_max_exp10 {
		return 0, false
	}
	// normalization
	clz := bits.leading_zeros_64(mantissa)
	man := mantissa << u64(clz)
	mut ret_exp2 := u64(((i64(217706) * i64(exp10)) >> 16) + 64 + 1023) - u64(clz)
	// multiplication
	idx := exp10 - eisel_lemire_min_exp10
	mut x_hi, mut x_lo := bits.mul_64(man, eisel_lemire_pow10_hi[idx])
	// wider approximation
	if (x_hi & 0x1FF) == 0x1FF && x_lo + man < man {
		y_hi, y_lo := bits.mul_64(man, eisel_lemire_pow10_lo[idx])
		mut merged_hi := x_hi
		merged_lo := x_lo + y_hi
		if merged_lo < x_lo {
			merged_hi++
		}
		if (merged_hi & 0x1FF) == 0x1FF && merged_lo + 1 == 0 && y_lo + man < man {
			return 0, false
		}
		x_hi = merged_hi
		x_lo = merged_lo
	}
	// shifting to 54 bits
	msb := x_hi >> 63
	mut ret_mantissa := x_hi >> (msb + 9)
	ret_exp2 -= (1 ^ msb)
	// half-way ambiguity
	if x_lo == 0 && (x_hi & 0x1FF) == 0 && (ret_mantissa & 3) == 1 {
		return 0, false
	}
	// from 54 to 53 bits
	ret_mantissa += (ret_mantissa & 1)
	ret_mantissa >>= 1
	if (ret_mantissa >> 53) > 0 {
		ret_mantissa >>= 1
		ret_exp2 += 1
	}
	// ret_exp2 0 or wrapped: subnormal space; >= 0x7FF: Inf/NaN space
	if ret_exp2 - 1 >= 0x7FF - 1 {
		return 0, false
	}
	mut ret_bits := (ret_exp2 << 52) | (ret_mantissa & 0x000FFFFFFFFFFFFF)
	if neg {
		ret_bits |= u64(0x8000000000000000)
	}
	return ret_bits, true
}

// Decimal is an arbitrary-precision decimal: 0.d[0..nd] * 10^dp.
struct Decimal {
mut:
	d     [800]u8 // digits, big-endian, ASCII
	nd    int     // digits used
	dp    int     // decimal point
	neg   bool
	trunc bool // nonzero digits were dropped after d[nd-1]
}

@[direct_array_access]
fn (mut a Decimal) set(s string, start int, end int) {
	mut i := start
	mut ndigits := 0 // significant digits read, stored or not
	for i < end && s[i] >= `0` && s[i] <= `9` {
		c := s[i]
		i++
		if c == `0` && ndigits == 0 {
			continue
		}
		ndigits++
		if a.nd < a.d.len {
			a.d[a.nd] = c
			a.nd++
		} else if c != `0` {
			a.trunc = true
		}
	}
	a.dp = ndigits
	if i < end && s[i] == `.` {
		i++
		for i < end && s[i] >= `0` && s[i] <= `9` {
			c := s[i]
			i++
			if c == `0` && ndigits == 0 {
				a.dp--
				continue
			}
			ndigits++
			if a.nd < a.d.len {
				a.d[a.nd] = c
				a.nd++
			} else if c != `0` {
				a.trunc = true
			}
		}
	}
	if i < end && (s[i] == `e` || s[i] == `E`) {
		i++
		mut esign := 1
		if i < end {
			if s[i] == `+` {
				i++
			} else if s[i] == `-` {
				esign = -1
				i++
			}
		}
		mut e := 0
		for i < end && s[i] >= `0` && s[i] <= `9` {
			if e < max_exp10_read {
				e = e * 10 + int(s[i] - `0`)
			}
			i++
		}
		a.dp += e * esign
	}
	a.trim()
}

@[direct_array_access]
fn (mut a Decimal) trim() {
	for a.nd > 0 && a.d[a.nd - 1] == `0` {
		a.nd--
	}
	if a.nd == 0 {
		a.dp = 0
	}
}

// the largest shift one pass takes without overflowing u64 (9 << k must fit)
const decimal_max_shift = 60

// right_shift divides by 2^k, k <= decimal_max_shift.
@[direct_array_access]
fn (mut a Decimal) right_shift(k u64) {
	mut r := 0 // read index
	mut w := 0 // write index
	mut n := u64(0)
	// pick up enough leading digits to cover the first shift
	for (n >> k) == 0 {
		if r >= a.nd {
			if n == 0 {
				a.nd = 0
				return
			}
			for (n >> k) == 0 {
				n = n * 10
				r++
			}
			break
		}
		n = n * 10 + u64(a.d[r] - `0`)
		r++
	}
	a.dp -= r - 1
	mask := (u64(1) << k) - 1
	// pick up a digit, put down a digit
	for r < a.nd {
		c := u64(a.d[r] - `0`)
		dig := n >> k
		n &= mask
		a.d[w] = u8(dig) + `0`
		w++
		n = n * 10 + c
		r++
	}
	// put down the extra digits
	for n > 0 {
		dig := n >> k
		n &= mask
		if w < a.d.len {
			a.d[w] = u8(dig) + `0`
			w++
		} else if dig > 0 {
			a.trunc = true
		}
		n = n * 10
	}
	a.nd = w
	a.trim()
}

// prefix_is_less_than reports whether the digits d[0..nd] read as less than `cutoff`.
@[direct_array_access]
fn (a &Decimal) prefix_is_less_than(cutoff string) bool {
	for i in 0 .. cutoff.len {
		if i >= a.nd {
			return true
		}
		if a.d[i] != cutoff[i] {
			return a.d[i] < cutoff[i]
		}
	}
	return false
}

// left_shift multiplies by 2^k, k <= decimal_max_shift.
@[direct_array_access]
fn (mut a Decimal) left_shift(k u64) {
	mut delta := decimal_left_cheats_delta[k]
	if a.prefix_is_less_than(decimal_left_cheats_cutoff[k]) {
		delta--
	}
	mut r := a.nd // read index
	mut w := a.nd + delta // write index
	mut n := u64(0)
	// pick up a digit, put down a digit
	r--
	for r >= 0 {
		n += u64(a.d[r] - `0`) << k
		quo := n / 10
		rem := n - 10 * quo
		w--
		if w < a.d.len {
			a.d[w] = u8(rem) + `0`
		} else if rem != 0 {
			a.trunc = true
		}
		n = quo
		r--
	}
	// put down the extra digits
	for n > 0 {
		quo := n / 10
		rem := n - 10 * quo
		w--
		if w < a.d.len {
			a.d[w] = u8(rem) + `0`
		} else if rem != 0 {
			a.trunc = true
		}
		n = quo
	}
	a.nd += delta
	if a.nd >= a.d.len {
		a.nd = a.d.len
	}
	a.dp += delta
	a.trim()
}

// shift multiplies (k > 0) or divides (k < 0) by 2^|k|.
fn (mut a Decimal) shift(k_ int) {
	mut k := k_
	if a.nd == 0 {
		return
	}
	if k > 0 {
		for k > decimal_max_shift {
			a.left_shift(decimal_max_shift)
			k -= decimal_max_shift
		}
		a.left_shift(u64(k))
	} else if k < 0 {
		for k < -decimal_max_shift {
			a.right_shift(decimal_max_shift)
			k += decimal_max_shift
		}
		a.right_shift(u64(-k))
	}
}

// should_round_up: rounding the digits at nd, ties to even (a dropped nonzero tail
// is above the tie).
@[direct_array_access]
fn (a &Decimal) should_round_up(nd int) bool {
	if nd < 0 || nd >= a.nd {
		return false
	}
	if a.d[nd] == `5` && nd + 1 == a.nd {
		if a.trunc {
			return true
		}
		return nd > 0 && (a.d[nd - 1] - `0`) % 2 == 1
	}
	return a.d[nd] >= `5`
}

// rounded_integer answers the integer part, rounded to nearest-even.
@[direct_array_access]
fn (a &Decimal) rounded_integer() u64 {
	if a.dp > 20 {
		return u64(0xFFFFFFFFFFFFFFFF)
	}
	mut i := 0
	mut n := u64(0)
	for i < a.dp && i < a.nd {
		n = n * 10 + u64(a.d[i] - `0`)
		i++
	}
	for i < a.dp {
		n *= 10
		i++
	}
	if a.should_round_up(a.dp) {
		n++
	}
	return n
}

const decimal_powtab = [1, 3, 6, 9, 13, 16, 19, 23, 26]!

const f64_mantbits = 52

const f64_expbits = 11

const f64_bias = -1023

fn f64_assemble(mant u64, exp int, neg bool) u64 {
	mut b := mant & ((u64(1) << f64_mantbits) - 1)
	b |= u64((exp - f64_bias) & ((1 << f64_expbits) - 1)) << f64_mantbits
	if neg {
		b |= u64(1) << 63
	}
	return b
}

// float_bits answers the bits of the f64 nearest to the decimal, ties to even.
@[direct_array_access]
fn (mut d Decimal) float_bits() u64 {
	overflow := f64_assemble(0, (1 << f64_expbits) - 1 + f64_bias, d.neg)
	if d.nd == 0 {
		return f64_assemble(0, f64_bias, d.neg)
	}
	if d.dp > 310 {
		return overflow
	}
	if d.dp < -330 {
		return f64_assemble(0, f64_bias, d.neg)
	}
	// scale by powers of two into [0.5, 1)
	mut exp := 0
	for d.dp > 0 {
		n := if d.dp >= decimal_powtab.len { 27 } else { decimal_powtab[d.dp] }
		d.shift(-n)
		exp += n
	}
	for d.dp < 0 || (d.dp == 0 && d.d[0] < `5`) {
		n := if -d.dp >= decimal_powtab.len { 27 } else { decimal_powtab[-d.dp] }
		d.shift(n)
		exp -= n
	}
	// [0.5, 1) -> [1, 2)
	exp--
	// below the smallest exponent: denormalize
	if exp < f64_bias + 1 {
		n := f64_bias + 1 - exp
		d.shift(-n)
		exp += n
	}
	if exp - f64_bias >= (1 << f64_expbits) - 1 {
		return overflow
	}
	// extract 1 + mantbits bits
	d.shift(1 + f64_mantbits)
	mut mant := d.rounded_integer()
	// rounding may have added a bit
	if mant == (u64(2) << f64_mantbits) {
		mant >>= 1
		exp++
		if exp - f64_bias >= (1 << f64_expbits) - 1 {
			return overflow
		}
	}
	// subnormal
	if (mant & (u64(1) << f64_mantbits)) == 0 {
		exp = f64_bias
	}
	return f64_assemble(mant, exp, d.neg)
}

// atof64_bits answers the bits of the correctly rounded f64 of the literal `sc` read
// from `s`.
fn atof64_bits(s string, sc FloatScan) u64 {
	if !sc.trunc {
		f, ok := atof64_exact(sc.mantissa, sc.exp10, sc.neg)
		if ok {
			mut u := Float64u{
				f: f
			}
			return unsafe { u.u }
		}
	}
	b, ok := eisel_lemire64(sc.mantissa, sc.exp10, sc.neg)
	if ok {
		if !sc.trunc {
			return b
		}
		// the dropped digits lie in (mantissa, mantissa+1): sure when both agree
		b_up, ok_up := eisel_lemire64(sc.mantissa + 1, sc.exp10, sc.neg)
		if ok_up && b == b_up {
			return b
		}
	}
	mut d := Decimal{
		neg: sc.neg
	}
	d.set(s, sc.start, sc.end)
	return d.float_bits()
}

const decimal_left_cheats_delta = [0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 6, 6, 6,
	7, 7, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 12, 12, 12, 13, 13, 13, 13, 14, 14,
	14, 15, 15, 15, 16, 16, 16, 16, 17, 17, 17, 18, 18, 18, 19]!
const decimal_left_cheats_cutoff = [
	'', // * 2^0
	'5', // * 2^1
	'25', // * 2^2
	'125', // * 2^3
	'625', // * 2^4
	'3125', // * 2^5
	'15625', // * 2^6
	'78125', // * 2^7
	'390625', // * 2^8
	'1953125', // * 2^9
	'9765625', // * 2^10
	'48828125', // * 2^11
	'244140625', // * 2^12
	'1220703125', // * 2^13
	'6103515625', // * 2^14
	'30517578125', // * 2^15
	'152587890625', // * 2^16
	'762939453125', // * 2^17
	'3814697265625', // * 2^18
	'19073486328125', // * 2^19
	'95367431640625', // * 2^20
	'476837158203125', // * 2^21
	'2384185791015625', // * 2^22
	'11920928955078125', // * 2^23
	'59604644775390625', // * 2^24
	'298023223876953125', // * 2^25
	'1490116119384765625', // * 2^26
	'7450580596923828125', // * 2^27
	'37252902984619140625', // * 2^28
	'186264514923095703125', // * 2^29
	'931322574615478515625', // * 2^30
	'4656612873077392578125', // * 2^31
	'23283064365386962890625', // * 2^32
	'116415321826934814453125', // * 2^33
	'582076609134674072265625', // * 2^34
	'2910383045673370361328125', // * 2^35
	'14551915228366851806640625', // * 2^36
	'72759576141834259033203125', // * 2^37
	'363797880709171295166015625', // * 2^38
	'1818989403545856475830078125', // * 2^39
	'9094947017729282379150390625', // * 2^40
	'45474735088646411895751953125', // * 2^41
	'227373675443232059478759765625', // * 2^42
	'1136868377216160297393798828125', // * 2^43
	'5684341886080801486968994140625', // * 2^44
	'28421709430404007434844970703125', // * 2^45
	'142108547152020037174224853515625', // * 2^46
	'710542735760100185871124267578125', // * 2^47
	'3552713678800500929355621337890625', // * 2^48
	'17763568394002504646778106689453125', // * 2^49
	'88817841970012523233890533447265625', // * 2^50
	'444089209850062616169452667236328125', // * 2^51
	'2220446049250313080847263336181640625', // * 2^52
	'11102230246251565404236316680908203125', // * 2^53
	'55511151231257827021181583404541015625', // * 2^54
	'277555756156289135105907917022705078125', // * 2^55
	'1387778780781445675529539585113525390625', // * 2^56
	'6938893903907228377647697925567626953125', // * 2^57
	'34694469519536141888238489627838134765625', // * 2^58
	'173472347597680709441192448139190673828125', // * 2^59
	'867361737988403547205962240695953369140625', // * 2^60
]!
