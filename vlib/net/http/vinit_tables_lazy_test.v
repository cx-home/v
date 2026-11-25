module http

// vinit_tables_lazy_test.v — https://github.com/cx-home/cx-private/issues/2068: net.http's
// three start-up tables (the HPACK Huffman code table, its decode map and common_header_map,
// ~32 KB together) are built on their first use, never by the module's const initialisation,
// so a program that never speaks HTTP (every cx program links net.http) carves no heap for
// them before main. A fresh test process has run _vinit; none of the three is built yet.
// The lookups then answer as the consts did, and a second use reads the published table.

fn test_start_builds_none_of_the_http_tables() {
	built := {
		'g_h2_huffman_table':      g_h2_huffman_table != unsafe { nil }
		'g_h2_huffman_decode_map': g_h2_huffman_decode_map != unsafe { nil }
		'g_common_header_map':     g_common_header_map != unsafe { nil }
	}
	mut early := []string{}
	for name, b in built {
		if b {
			early << name
		}
	}
	assert early.len == 0, 'built before their first use: ${early}'
	// first use builds each once and answers the table's rows
	assert h2_huffman_table().codes.len == 257
	assert h2_huffman_table().lengths[256] == 30
	assert h2_huffman_decode_map().len == 257
	assert h2_huffman_decode_map()[(u64(5) << 32) | 0x0] == 0x30
	assert canonicalize('content-type') == 'Content-Type'
	assert canonicalize('x-custom-thing') == 'X-Custom-Thing'
	assert common_header_map().len > 50
	p := g_h2_huffman_decode_map
	assert h2_huffman_decode([u8(0x07)]) or { []u8{} } == [u8(0x30)]
	assert g_h2_huffman_decode_map == p, 'a second use reads the published map, it does not rebuild'
	q := g_common_header_map
	assert canonicalize('accept') == 'Accept'
	assert g_common_header_map == q
}

// The published tables are reachable through their globals alone (the collector
// scans __global roots): a full collection keeps them whole.
fn test_published_http_tables_survive_collection() {
	_ := h2_huffman_decode_map()
	_ := common_header_map()
	gc_collect()
	gc_collect()
	assert h2_huffman_decode_map().len == 257
	assert h2_huffman_encode('www.example.com'.bytes()).len == 12
	out := h2_huffman_decode(h2_huffman_encode('www.example.com'.bytes())) or { []u8{} }
	assert out.bytestr() == 'www.example.com'
	assert common_header_map()['content-length'] == .content_length
}
