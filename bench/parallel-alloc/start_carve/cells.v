// cells.v — what a program's start-up costs the heap (vgc_start_carve_test.v).
//
// A module const allocates one object in each of the 32 smallest size classes
// (8 .. 1024 bytes), once conservatively scanned and once pointer-free: 64 span
// classes touched before main. main prints, as its first act, the bytes carved
// from the arenas and the bytes allocated. Built with `-d start_carve_control`
// the const allocates nothing, so the difference between the two programs is
// what touching those span classes at start-up costs.
//
//   ./v -gc e run cells.v     prints `carved=<n> allocated=<n> cells=<n>`
module main

const cells = make_cells()

fn make_cells() []voidptr {
	mut out := []voidptr{cap: 64}
	$if !start_carve_control ? {
		for n in [8, 16, 24, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 256,
			288, 320, 352, 384, 416, 448, 480, 512, 576, 640, 704, 768, 896, 1024] {
			out << unsafe { malloc(n) }
			out << unsafe { malloc_noscan(n) }
		}
	}
	return out
}

fn main() {
	carved := vgc_carved_probe()
	allocated := gc_total_allocated()
	println('carved=${carved} allocated=${allocated} cells=${cells.len}')
}
