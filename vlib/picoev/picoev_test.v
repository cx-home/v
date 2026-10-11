module picoev

fn test_if_all_file_descriptors_are_properly_initialized() {
	mut pv := &Picoev{}
	pv.init()

	for i in 0 .. max_fds {
		assert unsafe { pv.file_descriptors[i] } != unsafe { nil }
		assert unsafe { pv.file_descriptors[i].loop_id } == -1
		assert unsafe { pv.file_descriptors[i].fd } == 0
	}
}

const timeout_test_fd = 7

@[heap]
struct TimeoutHits {
mut:
	n int
}

fn timeout_test_cb(_fd int, events int, cb_arg voidptr) {
	if events & picoev_timeout != 0 {
		mut pv := unsafe { &Picoev(cb_arg) }
		mut hits := unsafe { &TimeoutHits(pv.user_data) }
		hits.n++
	}
}

// One timeout scan per second, not per loop pass: at 10k connections a scan per
// pass walked ~900 entries per reactor on every event (cx-platform-xap#20).
fn test_timeouts_are_scanned_once_per_second_and_still_fire() {
	mut hits := &TimeoutHits{}
	mut pv := &Picoev{
		user_data: voidptr(hits)
	}
	pv.init()
	pv.loop = &LoopType{
		id: 0
	}
	pv.loop.now = 1000
	for fd in 100 .. 600 {
		pv.timeouts[fd] = 1000 + 8
	}
	unsafe {
		pv.file_descriptors[timeout_test_fd].fd = timeout_test_fd
		pv.file_descriptors[timeout_test_fd].loop_id = 0
		pv.file_descriptors[timeout_test_fd].cb = timeout_test_cb
	}
	pv.set_timeout(timeout_test_fd, 1)
	for _ in 0 .. 1000 {
		pv.handle_timeout_once_per_second()
	}
	assert pv.timeout_scans == 1
	assert hits.n == 0
	pv.loop.now = 1001
	for _ in 0 .. 1000 {
		pv.handle_timeout_once_per_second()
	}
	assert pv.timeout_scans == 2
	assert hits.n == 1
	assert timeout_test_fd !in pv.timeouts
	assert pv.timeouts.len == 500
}
