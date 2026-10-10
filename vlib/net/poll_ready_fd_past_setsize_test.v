module main

import net
import time

// poll_ready_fd_past_setsize_test.v — net's waits work on a descriptor past
// FD_SETSIZE (1024): a dial, an accept, a read that times out and a read that
// gets data (cx-home/v#30). They were select(2), which macOS fails with EINVAL
// for such a descriptor and glibc's FD_SET overflows the fd_set for.

fn C.dup(fd i32) i32
fn C.close(fd i32) i32

// hold_descriptors_past opens descriptors (dups of stderr) until the next
// descriptor the process gets is above `n`; the caller closes them. Empty when
// the process may not open that many (a low RLIMIT_NOFILE): the test skips.
fn hold_descriptors_past(n int) []int {
	mut held := []int{}
	for {
		fd := int(C.dup(2))
		if fd < 0 {
			for h in held {
				C.close(h)
			}
			return []int{}
		}
		held << fd
		if fd >= n {
			return held
		}
	}
	return held
}

fn test_waits_on_descriptors_past_fd_setsize() {
	held := hold_descriptors_past(1100)
	if held.len == 0 {
		eprintln('skip: this process may not open 1100 descriptors')
		return
	}
	defer {
		for fd in held {
			C.close(fd)
		}
	}
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		l.close() or {}
	}
	port := l.addr()!.port()!
	mut c := net.dial_tcp('127.0.0.1:${port}')!
	defer {
		c.close() or {}
	}
	l.set_accept_timeout(5 * time.second)
	mut s := l.accept()!
	defer {
		s.close() or {}
	}
	assert s.sock.handle > 1024
	assert c.sock.handle > 1024
	s.set_read_timeout(150 * time.millisecond)
	mut buf := []u8{len: 16}
	if _ := s.read(mut buf) {
		assert false, 'nothing was sent: the read must time out'
	} else {
		assert err.code() == net.err_timed_out_code, 'a quiet read must time out, got: ${err}'
	}
	c.write_string('hi')!
	s.set_read_timeout(5 * time.second)
	n := s.read(mut buf)!
	assert buf[..n].bytestr() == 'hi'
	assert net.poll_ready(s.sock.handle, .write, time.second)!
	assert !net.poll_ready(s.sock.handle, .read, 50 * time.millisecond)!
}

// A listener past FD_SETSIZE blocked in accept() wakes when another thread
// closes it — the stop pattern servers use, which select gives on macOS and
// poll alone does not (v_poll_one.h checks the descriptor between slices).
fn test_close_wakes_an_accept_on_a_descriptor_past_fd_setsize() {
	held := hold_descriptors_past(1100)
	if held.len == 0 {
		eprintln('skip: this process may not open 1100 descriptors')
		return
	}
	defer {
		for fd in held {
			C.close(fd)
		}
	}
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	assert l.sock.handle > 1024
	done := chan bool{cap: 1}
	spawn fn [mut l, done] () {
		l.accept() or {}
		done <- true
	}()
	time.sleep(100 * time.millisecond)
	t0 := time.now()
	l.close() or {}
	select {
		_ := <-done {
			assert time.since(t0) < 2 * time.second
		}
		5 * time.second {
			assert false, 'accept() on a closed listener past FD_SETSIZE never returned'
		}
	}
}
