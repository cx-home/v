import strconv

// cx-home/v#25: atof64 answers the correctly rounded f64 (IEEE 754
// round-half-to-even), the value Python's float(), C's strtod and Go's
// strconv.ParseFloat answer. The bit patterns below are Python's.
struct Case {
	s    string
	bits u64
}

const correct_cases = [
	Case{'1e23', u64(0x44b52d02c7e14af6)},
	Case{'9007199254740993.0', u64(0x4340000000000000)}, // halfway: ties to even
	Case{'86379243.715156e10', u64(0x43a7f99d4a402ce2)},
	Case{'9007199254740995', u64(0x4340000000000002)}, // halfway: ties to even (up)
	Case{'9007199254740993.0000000000000000000001', u64(0x4340000000000001)}, // just above halfway
	Case{'2.2250738585072011e-308', u64(0x000fffffffffffff)}, // largest subnormal
	Case{'2.2250738585072012e-308', u64(0x0010000000000000)}, // smallest normal
	Case{'4.9406564584124654e-324', u64(0x0000000000000001)}, // smallest subnormal
	Case{'2.4703282292062328e-324', u64(0x0000000000000001)}, // just above half the smallest subnormal
	Case{'2.4703282292062327e-324', u64(0x0000000000000000)}, // just below: zero
	Case{'123456789012345678e-340', u64(0x0000000000000002)}, // 18 digits, tiny exponent: subnormal, not zero
	Case{'1.7976931348623157e308', u64(0x7fefffffffffffff)}, // max
	Case{'1.7976931348623158e308', u64(0x7fefffffffffffff)}, // rounds down to max
	Case{'1.7976931348623159e308', u64(0x7ff0000000000000)}, // overflows to +inf
	Case{'0.1', u64(0x3fb999999999999a)},
	Case{'3.141592653589793238462643383279502884197', u64(0x400921fb54442d18)},
	Case{'-0.0', u64(0x8000000000000000)},
	Case{'1e-400', u64(0)},
	Case{'1e400', u64(0x7ff0000000000000)},
	Case{'-1e400', u64(0xfff0000000000000)},
	Case{'7.3177701707893310e+15', u64(0x4339ff792393edd3)},
	Case{'5e-324', u64(1)},
	Case{'179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497791.9999999999999999999999999999999999999999999999999999999999999999999999', u64(0x7fefffffffffffff)},
	Case{'1000000000000000000000000000000000000000000000000000000000000000000000000000000000001e-84', u64(0x3ff0000000000000)},
]

fn test_atof64_is_correctly_rounded() {
	mut bad := []string{}
	for c in correct_cases {
		f := strconv.atof64(c.s) or { panic('${c.s}: ${err}') }
		got := unsafe { *(&u64(&f)) }
		if got != c.bits {
			bad << '${c.s}: got 0x${got:016x} want 0x${c.bits:016x}'
		}
	}
	assert bad == []string{}, bad.join('\n')
}

fn test_string_f64_is_correctly_rounded() {
	assert '1e23'.f64() == 1e23
	assert '9007199254740993.0'.f64() == 9007199254740992.0
}

fn C.strtod(&char, &&char) f64

// splitmix64: a seeded, portable stream of literals
struct Mix {
mut:
	s u64
}

fn (mut m Mix) next() u64 {
	m.s += u64(0x9e3779b97f4a7c15)
	mut z := m.s
	z = (z ^ (z >> 30)) * u64(0xbf58476d1ce4e5b9)
	z = (z ^ (z >> 27)) * u64(0x94d049bb133111eb)
	return z ^ (z >> 31)
}

fn (mut m Mix) literal() string {
	shape := m.next() % 4
	nd := int(1 + m.next() % 25)
	mut digits := []u8{len: nd}
	for i in 0 .. nd {
		digits[i] = u8(`0` + m.next() % 10)
	}
	ds := digits.bytestr()
	match shape {
		0 {
			// a short integer significand anywhere in the exponent range
			e := int(m.next() % 680) - 350
			return '${ds}e${e}'
		}
		1 {
			// a point inside the digits
			p := int(m.next() % u64(nd + 1))
			e := int(m.next() % 640) - 330
			return '${ds[..p]}.${ds[p..]}e${e}'
		}
		2 {
			// the shortest round-trip text of a random double, +-1 in the last digit:
			// the literals nearest to the f64 grid
			mut u := Float64u2{
				u: m.next() & u64(0x7fefffffffffffff)
			}
			f := unsafe { u.f }
			return '${f:.17e}'.replace('e+', 'e')
		}
		else {
			// a plain decimal, no exponent
			p := int(m.next() % u64(nd + 1))
			return '${ds[..p]}.${ds[p..]}'
		}
	}
}

union Float64u2 {
mut:
	f f64
	u u64
}

// every literal of a seeded sweep answers what the C library's strtod answers
// (correctly rounded on glibc, musl, the BSDs and macOS).
fn test_atof64_sweep_matches_strtod() {
	mut m := Mix{
		s: 25
	}
	mut bad := []string{}
	for _ in 0 .. 200_000 {
		lit := m.literal()
		want := C.strtod(&char(lit.str), unsafe { nil })
		got := strconv.atof64(lit) or { panic('${lit}: ${err}') }
		gb := unsafe { *(&u64(&got)) }
		wb := unsafe { *(&u64(&want)) }
		if gb != wb && bad.len < 20 {
			bad << '${lit}: got 0x${gb:016x} want 0x${wb:016x}'
		}
	}
	assert bad == []string{}, bad.join('\n')
}
