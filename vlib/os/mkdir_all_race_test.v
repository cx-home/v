import os
import sync

// mkdir_all has `mkdir -p` semantics under a race: when several threads (or processes)
// create the same new folder at once, a folder that is there by the time mkdir fails is
// success, not `File exists` (cx-private's test-connector-real panicked in
// setup_new_vtmp_folder on 2026-10-10).
fn test_mkdir_all_concurrent_same_path() {
	root := os.join_path(os.vtmp_dir(), 'mkdir_all_race_${os.getpid()}')
	defer {
		os.rmdir_all(root) or {}
	}
	n := 32
	for round in 0 .. 200 {
		target := os.join_path(root, 'r${round}', 'a', 'b', 'c', 'd', 'e', 'f')
		errs := chan string{cap: n}
		mut ready := sync.new_waitgroup()
		ready.add(1)
		mut threads := []thread{}
		for _ in 0 .. n {
			threads << spawn fn [target, errs, mut ready] () {
				ready.wait()
				os.mkdir_all(target) or { errs <- err.msg() }
			}()
		}
		ready.done()
		threads.wait()
		errs.close()
		mut got := []string{}
		for {
			e := <-errs or { break }
			got << e
		}
		assert got == [], 'round ${round}: ${got.len} of ${n} failed, first: ${got[0]}'
		assert os.is_dir(target)
	}
}

fn test_mkdir_all_refuses_a_file_in_the_way() {
	root := os.join_path(os.vtmp_dir(), 'mkdir_all_file_${os.getpid()}')
	os.mkdir_all(root)!
	defer {
		os.rmdir_all(root) or {}
	}
	f := os.join_path(root, 'plain')
	os.write_file(f, 'x')!
	if _ := os.mkdir_all(os.join_path(f, 'sub')) {
		assert false, 'mkdir_all under a plain file must fail'
	}
}
