// vgc_map_metas_noscan_test.v — a map's metas (u32 hash bits and key-value
// indices, pointer-free; vcalloc_noscan at new_map, v_realloc at
// reserve_metas) lie in a noscan span from the map's birth through its
// growth, as a field of a heap struct and as a local (cx-home/v#56: the
// verifier's missed words were two metas pairs read as one 64-bit word in a
// scanned, permanent 65,616-byte buffer — a map of 4096 int keys' metas —
// naming a dead young object: perm_gen_verify7's 0x191a/0x191b/0x191c
// reports at offset 30,192 of both maps' metas). Its own process (a fresh
// heap).
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_map_metas_noscan_test.v
module main

@[heap]
struct Rec {
mut:
	a u64
}

@[heap]
struct Old {
mut:
	m    map[int]&Rec
	mids map[int]u64
}

fn test_a_maps_metas_lie_in_a_noscan_span_through_its_growth() {
	mut o := &Old{}
	assert vgc_map_metas_noscan_probe(unsafe { voidptr(&o.m) }), "a fresh map field's metas are not noscan"
	mut metas0 := usize(0)
	for k in 0 .. 4096 {
		o.m[k] = &Rec{
			a: u64(k)
		}
		o.mids[k] = u64(k)
		metas := vgc_map_metas_addr_probe(unsafe { voidptr(&o.m) })
		if metas != metas0 {
			println('vgc_map_metas_noscan: at ${k + 1} keys the metas moved to ${metas} (noscan=${vgc_map_metas_noscan_probe(unsafe { voidptr(&o.m) })})')
			metas0 = metas
		}
		assert vgc_map_metas_noscan_probe(unsafe { voidptr(&o.m) }), 'the map field\'s metas are not noscan at ${
			k + 1} keys'
	}
	assert vgc_map_metas_noscan_probe(unsafe { voidptr(&o.m) }), "the pointer-valued map field's metas are not noscan at 4096 keys"
	assert vgc_map_metas_noscan_probe(unsafe { voidptr(&o.mids) }), "the u64-valued map field's metas are not noscan at 4096 keys"
	mut m := map[int]&Rec{}
	assert vgc_map_metas_noscan_probe(unsafe { voidptr(&m) }), "a fresh local map's metas are not noscan"
	for k in 0 .. 4096 {
		m[k] = &Rec{
			a: u64(k)
		}
	}
	assert vgc_map_metas_noscan_probe(unsafe { voidptr(&m) }), "the local map's metas are not noscan at 4096 keys"
	println('vgc_map_metas_noscan: the metas of ${o.m.len}-, ${o.mids.len}- and ${m.len}-key maps lie in noscan spans')
}

fn test_a_noscan_buffer_stays_noscan_through_a_realloc() {
	mut p := unsafe { vcalloc_noscan(144) }
	assert vgc_noscan_probe(p), 'a fresh vcalloc_noscan buffer is not noscan'
	for n in [264, 536, 1048, 2096, 4200, 8400, 16800, 33000, 66000] {
		p = unsafe { v_realloc(p, n) }
		assert vgc_noscan_probe(p), 'the buffer is not noscan after v_realloc to ${n} bytes'
	}
	mut q := unsafe { vcalloc_noscan(144) }
	mut was := 144
	for n in [264, 536, 1048, 2096, 4200, 8400, 16800, 33000, 66000] {
		q = unsafe { realloc_data(q, was, n) }
		assert vgc_noscan_probe(q), 'the buffer is not noscan after realloc_data to ${n} bytes'
		was = n
	}
	println('vgc_map_metas_noscan: a noscan buffer stays noscan through v_realloc and realloc_data to 66000 bytes (${usize(p)} ${usize(q)})')
}
