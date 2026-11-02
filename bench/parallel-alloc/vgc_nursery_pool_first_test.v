// vgc_nursery_pool_first_test.v — under the young regime with the nursery
// (cx-home/v#56 lever 7) a class span comes from the pool before the
// nursery's fresh carve (vgc_central_get_fresh in
// vlib/builtin/vgc_d_vgc.c.v): young/pool_first.v drops and collects nine
// waves of 400,000 48-byte records, and the committed bytes after the ninth
// wave read within half a wave of the bytes after the first. With the
// nursery first (3d9761a23) every wave carved fresh spans from the bump and
// the freed ones came back round only once the 16 GB range was spent —
// binary-trees 18 read 10.4–10.6 GB of peak RSS against 0.5 on the stack's
// collector (measure/collector-epic-75, the F rows); here the committed
// bytes grow by eight waves.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_nursery_pool_first_test.v
module main

import os

fn build(name string) string {
	src := os.join_path(@DIR, name)
	exe := os.join_path(os.vtmp_dir(), 'vgc_nursery_pool_first_${os.getpid()}')
	r :=
		os.execute('${os.quoted_path(@VEXE)} -gc e -cc cc -o ${os.quoted_path(exe)} ${os.quoted_path(src)}')
	assert r.exit_code == 0, r.output
	return exe
}

fn field(out string, name string) string {
	line := out.split_into_lines().filter(it.starts_with('committed='))
	assert line.len == 1, 'the committed line in:\n${out}'
	w := line[0].split(' ').filter(it.starts_with('${name}='))
	assert w.len == 1, '${name} in: ${line[0]}'
	return w[0].all_after('=')
}

fn test_the_committed_bytes_level_off_under_the_nursery() {
	exe := build('young/pool_first.v')
	defer {
		os.rm(exe) or {}
	}
	r := os.execute('VGC_YOUNG=1 ${os.quoted_path(exe)}')
	assert r.exit_code == 0, r.output
	parts := r.output.split_into_lines().filter(it.starts_with('committed='))[0].split(' ')
	c1 := parts[0].all_after('=').u64()
	c9b := parts[1].u64()
	wave := field(r.output, 'wave').u64()
	println('vgc_nursery_pool_first: committed ${c1} after wave 1, ${c9b} after wave 9 (a wave ${wave} bytes)')
	assert c9b >= c1, 'the committed bytes shrank: ${r.output}'
	assert c9b - c1 <= wave / 2, 'the committed bytes grew by ${(c9b - c1) / wave} waves over eight dropped waves: ${c1} -> ${c9b} (a wave ${wave} bytes)'
}
