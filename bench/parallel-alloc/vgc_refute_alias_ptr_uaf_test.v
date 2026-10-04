// Refutation: []BigRef with `type BigRef = &Big` is emitted _noscan
// (contains_ptr resolves the alias through final_sym, dropping the pointer),
// so its referents are swept while live: a read-after-reuse shows the bytes.
module main

struct Big {
mut:
	w [512]u64 // 4 KiB, pointer-free
}

type BigRef = &Big

@[noinline]
fn build() []BigRef {
	mut a := []BigRef{}
	for i in 0 .. 2000 {
		mut b := &Big{}
		for k in 0 .. 512 {
			b.w[k] = u64(0x1111) * u64(i + 1)
		}
		a << BigRef(b)
	}
	return a
}

@[noinline]
fn churn() []voidptr {
	mut keep := []voidptr{}
	for _ in 0 .. 4000 {
		mut c := &Big{}
		for k in 0 .. 512 {
			c.w[k] = 0xdeadbeef
		}
		keep << voidptr(c)
	}
	return keep
}

fn test_alias_pointer_array_referents_survive() {
	a := build()
	for _ in 0 .. 3 {
		gc_collect()
	}
	k := churn()
	mut bad := 0
	for i, r in a {
		b := &Big(r)
		if b.w[0] != u64(0x1111) * u64(i + 1) || b.w[511] != u64(0x1111) * u64(i + 1) {
			bad++
		}
	}
	println('ALIASUAF corrupted=${bad} of ${a.len} (keep ${k.len})')
	assert bad == 0
}
