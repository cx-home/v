// cx-home/v#49: a `v build-module` layer is compiled in its own type universe,
// and an importing program numbers its types differently. The layer's C must
// not depend on that numbering — every index past the fixed builtin block is
// read through the program-defined `_v_type_idx_<cname>()` — or a cached layer
// can never be linked into a larger program (the cx-private#864 guard emits it
// inline instead). VUSECACHE_TYPE_SHIFT moves every such index; the layer's C
// at two shifts must be the same text.
import os

const vexe = @VEXE

const fixture = os.join_path(os.dir(@FILE), 'testdata', 'usecache_shift', 'shiftmod')

fn layer_c(root string, mod_path string, shift int) string {
	vtmp := os.join_path(root, 'vtmp_${shift}')
	vcache := os.join_path(root, 'vcache_${shift}')
	os.mkdir_all(vtmp) or { panic(err) }
	os.mkdir_all(vcache) or { panic(err) }
	cmd := 'VUSECACHE_TYPE_SHIFT=${shift} VTMP=${os.quoted_path(vtmp)} VCACHE=${os.quoted_path(vcache)} ${os.quoted_path(vexe)} -g -gc none build-module ${os.quoted_path(mod_path)}'
	res := os.execute(cmd)
	assert res.exit_code == 0, '${cmd}\n${res.output}'
	mut cfiles := os.walk_ext(vtmp, '.c')
	cfiles.sort()
	assert cfiles.len > 0, 'no C file kept under ${vtmp}'
	mut sb := []string{}
	for f in cfiles {
		for line in os.read_lines(f) or { panic(err) } {
			if line.contains('__v_usecache_shift_') {
				continue
			}
			sb << line.replace(vtmp, '<VTMP>').replace(vcache, '<VCACHE>')
		}
	}
	return sb.join('\n')
}

fn first_difference(a string, b string) string {
	al := a.split_into_lines()
	bl := b.split_into_lines()
	for i in 0 .. if al.len < bl.len { al.len } else { bl.len } {
		if al[i] != bl[i] {
			return 'line ${i + 1}:\n  shift 0: ${al[i]}\n  shift 7: ${bl[i]}'
		}
	}
	return 'lengths ${al.len} vs ${bl.len}'
}

fn check_layer(mod_path string) {
	root := os.join_path(os.vtmp_dir(), 'usecache_layer_shift_${os.getpid()}_${os.file_name(mod_path)}')
	os.rmdir_all(root) or {}
	defer {
		os.rmdir_all(root) or {}
	}
	c0 := layer_c(root, mod_path, 0)
	c7 := layer_c(root, mod_path, 7)
	assert c0 == c7, '${mod_path}: the layer C depends on the type numbering, first difference at ${first_difference(c0,
		c7)}'
}

fn test_fixture_layer_is_numbering_independent() {
	check_layer(fixture)
}

fn test_toml_layer_is_numbering_independent() {
	check_layer(os.join_path(@VEXEROOT, 'vlib', 'toml'))
}
