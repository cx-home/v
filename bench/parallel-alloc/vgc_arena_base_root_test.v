// vgc_arena_base_root_test.v — an arena's base address is collector
// metadata, not a root (cx-private #1783, batch I-1).
//
// The collector scans the data segments conservatively, and that includes its
// own vgc_heap struct (the per-thread caches hold real roots). vgc_heap's
// arena table stores each arena's base address. That address is also the
// address of the first object carved in the arena, so the scan kept that
// object alive, and everything it reaches, for the life of the process.
// vgc_arena_lo, the lowest arena's base, did the same for arena 0. Which
// object lands at an arena's base is a phase of the workload. When the
// VGCG-1 grow gate moved one carve, cx's streaming bench placed the root of
// its finished buffered result (24 MB) at the second arena's base. That set
// was then marked in every later cycle, and the bench slowed by 35 %
// (perf-ratchet streaming.streaming_ms, 92 -> 106 ms).
//
// The shape here is a chain longer than one arena, where each node points
// to the node allocated before it. The node that lands at the second
// arena's base reaches every node before it. After the chain is dropped and
// the heap collected, the marked set must be small. With the arena table
// scanned, it holds the whole first arena of nodes.
//
// No cx program can reach the allocator; the cx-gap note is in
// cx-private's batch I-1 RESULTS.md.
//
// Run: ./v -gc e -cc cc test bench/parallel-alloc/vgc_arena_base_root_test.v
module main

struct Node {
	prev &Node = unsafe { nil }
mut:
	pad  [1016]u64
}

const chain_bytes = 160 * 1024 * 1024 // more than two 64 MB arenas of nodes

// The marked set after the chain is dropped: the runtime's own live data is a
// few MB; one arena of retained nodes is ~64 MB.
const retained_bound = 16 * 1024 * 1024

@[noinline]
fn build_and_drop_chain() int {
	mut head := &Node(unsafe { nil })
	n := chain_bytes / int(sizeof(Node))
	for i in 0 .. n {
		head = &Node{
			prev: head
		}
		head.pad[i % 1016] = u64(i)
	}
	mut len := 0
	mut p := head
	for p != unsafe { nil } {
		len++
		p = p.prev
	}
	return len
}

// Overwrites the stack the chain builder used, so no stale stack word
// keeps a node alive and the measurement reads the data-segment roots only.
@[noinline]
fn scrub_stack() u64 {
	mut buf := [4096]u64{}
	for i in 0 .. buf.len {
		buf[i] = u64(i)
	}
	return buf[4095]
}

fn test_an_arena_base_does_not_root_the_object_carved_there() {
	len := build_and_drop_chain()
	_ := scrub_stack()
	gc_collect()
	gc_collect()
	retained := gc_heap_usage().total_bytes
	carved := gc_memory_use()
	println('vgc_arena_base_root: chain=${len} nodes (${chain_bytes} bytes) carved=${carved} retained_after_drop=${retained} bound=${retained_bound}')
	assert len == chain_bytes / int(sizeof(Node))
	assert carved > u64(chain_bytes), 'the chain did not span a second arena (carved ${carved})'
	assert retained < u64(retained_bound), '${retained} bytes stay marked after the chain was dropped (bound ${retained_bound}): an arena base address is rooting the node carved there'
}
