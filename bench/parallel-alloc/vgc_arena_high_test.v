// vgc_arena_high_test.v — the collector carves and uses arenas mapped above
// 4 TB (cx-home/v#69).
//
// On Linux a plain mmap lands near the top of the user address space (x86-64
// ~127 TB, arm64 ~256 TB); macOS hands out a few GB. The concurrent build's
// carve registered each arena's 64 MB chunks in card tables that covered the
// low 4 TB only (VGC_ADDR_MAP_SIZE 65536) and refused the carve above, so in an
// arm64 Linux container a -gc e program died at its first allocation: 'vgc: out
// of memory: 2480 bytes requested; arenas 0/1024' (cx-private#2019).
//
// The hook VGC_TEST_ARENA_HINT maps every arena carved after vgc_init at the
// given address and upward; macOS honors such hints, so the child's heap grows
// in arenas above 4 TB, as on Linux. The child builds ~80 MB of chains plus one
// oversized array, stores new nodes into old ones across concurrent cycles
// (the write barrier's cards), collects, and checks every node; it prints the
// highest object address it saw, which must lie above 4 TB.
//
// Run: ./v -gc e test bench/parallel-alloc/vgc_arena_high_test.v
module main

import os
import time

const four_tb = u64(1) << 42

@[heap]
struct Node {
mut:
	next &Node = unsafe { nil }
	pad  [4]u64
}

fn chain(id int, n int, mut top &u64) &Node {
	mut head := &Node(unsafe { nil })
	for i in 0 .. n {
		mut x := &Node{
			next: head
		}
		x.pad[0] = u64(id)
		x.pad[1] = u64(i)
		x.pad[2] = u64(id) * 1000003 + u64(i) * 7
		a := u64(usize(voidptr(x)))
		if a > *top {
			unsafe {
				*top = a
			}
		}
		head = x
	}
	return head
}

fn sum_chain(h &Node) u64 {
	mut s := u64(0)
	mut n := unsafe { h }
	for n != unsafe { nil } {
		if n.pad[2] != n.pad[0] * 1000003 + n.pad[1] * 7 {
			println('BAD node ${n.pad[0]} ${n.pad[1]}')
			exit(3)
		}
		s += n.pad[2]
		n = n.next
	}
	return s
}

fn high_main() {
	mut top := u64(0)
	mut heads := []&Node{}
	for step in 0 .. 16 {
		heads << chain(step, 100_000, mut &top)
		gc_collect()
	}
	// an oversized arena (one object larger than an arena)
	mut big := []u8{len: 80 * 1024 * 1024}
	big[big.len - 1] = 7
	ba := u64(usize(big.data))
	if ba > top {
		top = ba
	}
	// stores of new nodes into old ones, collections between: the cards of the
	// old nodes' pages must keep the new ones alive
	mut want := u64(0)
	for round in 0 .. 8 {
		for k in 0 .. heads.len {
			mut tail := chain(100 + round * 16 + k, 2_000, mut &top)
			mut last := tail
			for last.next != unsafe { nil } {
				last = last.next
			}
			last.next = heads[k]
			heads[k] = tail
		}
		gc_collect()
	}
	for h in heads {
		want += sum_chain(h)
	}
	gc_collect()
	mut got := u64(0)
	for h in heads {
		got += sum_chain(h)
	}
	assert got == want
	assert big[big.len - 1] == 7
	println('HIGH-OK=${got} top=0x${top.hex()} above4tb=${top >= four_tb} cycles=${gc_cycles()}')
}

fn watched(env map[string]string, limit_s int) (int, string) {
	log := os.join_path(os.temp_dir(), 'vgc_arena_high_${os.getpid()}.log')
	mut p := os.new_process('/bin/sh')
	p.set_args(['-c', 'exec "\$0" > "\$1" 2>&1', os.executable(), log])
	mut e := os.environ()
	e['VGC_AH_CHILD'] = '1'
	for k, v in env {
		e[k] = v
	}
	p.set_environment(e)
	p.run()
	deadline := time.now().add(limit_s * time.second)
	mut killed := false
	for p.is_alive() {
		if time.now() > deadline {
			p.signal_kill()
			killed = true
			break
		}
		time.sleep(20 * time.millisecond)
	}
	p.wait()
	code := if killed { -9 } else { p.code }
	p.close()
	mut out := os.read_file(log) or { '' }
	os.rm(log) or {}
	if killed {
		out += '\n<killed after ${limit_s} s>'
	}
	return code, out
}

fn check(name string, env map[string]string) {
	code, out := watched(env, 120)
	println('vgc_arena_high ${name}: exit=${code}: ${out.trim_space()}')
	assert code == 0, out
	assert out.contains('HIGH-OK='), out
	assert out.contains('above4tb=true'), 'the hook mapped no arena above 4 TB:\n${out}'
}

fn test_arenas_above_4tb() {
	if os.getenv('VGC_AH_CHILD') != '' {
		high_main()
		return
	}
	// 0x500_0000_0000 = 5 TB: past the old tables' 4 TB, below every platform's
	// user address space top
	check('stop-the-world cycles', {
		'VGC_TEST_ARENA_HINT': '0x50000000000'
		'VGC_CM':              '0'
	})
	check('concurrent cycles', {
		'VGC_TEST_ARENA_HINT': '0x50000000000'
		'VGC_CM':              '1'
	})
}
