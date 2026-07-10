// Test that locking a *value typed*, zero valued (never initialized)
// sync.Mutex fails LOUDLY, instead of silently providing no mutual exclusion.
//
// Background: on macOS, PTHREAD_MUTEX_INITIALIZER is not all zeros, so a
// zeroed pthread_mutex_t is invalid, and pthread_mutex_lock() on it fails
// with EINVAL. sync.Mutex.lock() used to ignore that return value - the
// "lock" was a silent no-op, and the data it guarded was corrupted quietly.
// Now it panics. On Linux/glibc, a zeroed mutex happens to be a valid
// initializer, so the same program locks normally and exits cleanly there -
// which is exactly why this class of bug presents as macOS-only failures.
import os
import sync

const vexe = os.getenv('VEXE')

const zeroed_mutex_program = '
import sync

__global (
	zeroed_lock sync.Mutex
)

fn main() {
	zeroed_lock.lock()
	zeroed_lock.unlock()
	println("zeroed value mutex lock/unlock completed")
}
'

const inited_value_mutex_program = '
import sync

fn main() {
	mut m := sync.Mutex{}
	m.init()
	m.lock()
	m.unlock()
	if m.try_lock() {
		m.unlock()
	}
	m.destroy()
	// a zero valued RwMutex is lazily initialized on first use by design
	mut rw := sync.RwMutex{}
	rw.lock()
	rw.unlock()
	rw.rlock()
	rw.runlock()
	println("initialized value mutex works")
}
'

fn run_program(tdir string, name string, source string) os.Result {
	program := os.join_path(tdir, name)
	os.write_file(program, source) or { panic(err) }
	return os.execute('${os.quoted_path(vexe)} -enable-globals run ${os.quoted_path(program)}')
}

fn test_zeroed_value_typed_mutex_lock_is_loud() {
	assert vexe != '', 'VEXE should be set'
	tdir := os.join_path(os.vtmp_dir(), 'zeroed_mutex_panic_${os.getpid()}')
	os.mkdir_all(tdir)!
	defer {
		os.rmdir_all(tdir) or {}
	}
	res := run_program(tdir, 'zeroed_mutex_program.v', zeroed_mutex_program)
	$if macos {
		// a zeroed pthread_mutex_t is invalid on Darwin -> loud panic,
		// naming the failed operation and the errno
		assert res.exit_code != 0, 'locking a zeroed value typed sync.Mutex should panic on macOS, output:\n${res.output}'
		assert res.output.contains('pthread_mutex_lock failed with EINVAL'), 'the panic message should name the operation and the errno, output:\n${res.output}'
		assert !res.output.contains('zeroed value mutex lock/unlock completed')
	} $else {
		// elsewhere a zeroed mutex may be a valid initializer (glibc), so the
		// program is allowed to finish normally; what is not allowed is a
		// nonzero pthread return being ignored - any failure must be loud
		if res.exit_code != 0 {
			assert res.output.contains('sync:'), 'a failing lock must panic loudly, output:\n${res.output}'
		}
	}
}

fn test_explicitly_initialized_value_mutex_still_works() {
	assert vexe != '', 'VEXE should be set'
	tdir := os.join_path(os.vtmp_dir(), 'inited_mutex_${os.getpid()}')
	os.mkdir_all(tdir)!
	defer {
		os.rmdir_all(tdir) or {}
	}
	res := run_program(tdir, 'inited_value_mutex_program.v', inited_value_mutex_program)
	assert res.exit_code == 0, 'a value typed mutex with an explicit .init() must keep working, output:\n${res.output}'
	assert res.output.contains('initialized value mutex works')
}

fn test_initialized_mutexes_still_work() {
	// the reference form
	mut m := sync.new_mutex()
	m.lock()
	m.unlock()
	assert m.try_lock()
	m.unlock()
	m.destroy()
	mut rw := sync.new_rwmutex()
	rw.lock()
	rw.unlock()
	rw.rlock()
	rw.runlock()
}
