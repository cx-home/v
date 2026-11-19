// vgc_net_park_flush_test.v — a thread that blocks in a socket wait gives up
// its cached spans, as one that parks on a channel does (cx-home/v#77,
// cx-home/v#36).
//
// Shape: vgc_park_flush_test.v's, with the park moved from a channel receive
// to a TCP read. 96 worker threads start one after another (each dials the
// test's own loopback listener, allocates three objects in each of eight size
// classes, keeps them live, writes one byte so the main thread knows it is
// about to block, then reads — nothing ever arrives until the end). A channel
// receive is a GC-safe region, and v#36 hands a thread's partly used spans to
// central.partial as it enters one, so the next thread refills from them. A
// socket wait (select/poll in vlib/net) entered no region: a `cx fabric-serve`
// reader thread, blocked in its read, kept a fresh 8 KB span per size class it
// had touched — about 34 spans, 270 KB, per idle thread at 110 connections.
// The carve over the workers' live bytes must stay under 2x, as the channel
// case does (9.4x before: 10.8 MB carved for 1.1 MB live, 96 threads x 8
// classes x an 8 KB span each; 1.4x with the region).
//
// Run: ./v test bench/parallel-alloc/vgc_net_park_flush_test.v
module main

import net

const nthreads = 96
const sizes = [16, 32, 64, 128, 256, 512, 1024, 2048]

struct Held {
mut:
	bufs [][]u8
}

fn worker(addr string, mut held Held) {
	mut c := net.dial_tcp(addr) or { panic('dial: ${err}') }
	c.set_read_timeout(net.infinite_timeout)
	mut keep := [][]u8{cap: 3 * sizes.len}
	for sz in sizes {
		for k in 0 .. 3 {
			keep << []u8{len: sz, init: u8(k)}
		}
	}
	held.bufs = keep
	// one byte: the main thread accepts the next worker only after this one
	// is about to block in its read
	c.write([u8(1)]) or { panic('write: ${err}') }
	mut buf := []u8{len: 4}
	c.read(mut buf) or {}
	c.close() or {}
}

fn test_threads_blocked_in_a_socket_read_do_not_keep_their_cached_spans() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('listen: ${err}') }
	addr := l.addr() or { panic('addr: ${err}') }
	mut helds := []&Held{cap: nthreads}
	mut servers := []&net.TcpConn{cap: nthreads}
	gc_collect()
	before := gc_memory_use()
	mut threads := []thread{cap: nthreads}
	for _ in 0 .. nthreads {
		mut h := &Held{}
		helds << h
		threads << spawn worker(addr.str(), mut h)
		mut s := l.accept() or { panic('accept: ${err}') }
		s.set_read_timeout(net.infinite_timeout)
		mut one := []u8{len: 1}
		s.read(mut one) or { panic('ready byte: ${err}') }
		servers << s
	}
	gc_collect()
	after := gc_memory_use()
	mut live := 0
	for h in helds {
		for b in h.bufs {
			live += b.len
		}
	}
	for mut s in servers {
		s.close() or {}
	}
	threads.wait()
	l.close() or {}
	carved := i64(after) - i64(before)
	ratio := f64(carved) / f64(live)
	eprintln('workers=${nthreads} live=${live} B carved=${carved} B (${carved / 1024} KB) ratio=${ratio:.1f}')
	assert ratio < 2.0, 'threads blocked in a socket read kept their cached spans: ${carved} B carved for ${live} B live (${ratio:.1f}x)'
}
