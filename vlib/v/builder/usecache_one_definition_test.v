// vtest build: !windows && !msvc
module builder

import os

// A `-usecache` build links the program translation unit together with one
// cached object per module. That only produces a correct binary while every
// symbol is DEFINED in exactly one of those objects: two definitions of the
// same symbol mean the binary runs whichever copy the linker picked, and the
// pick has nothing to do with which one is current.
//
// linux builds used to hide that class. `setup_ccompiler_options` added
// `-Xlinker -z -Xlinker muldefs` for cached builds, which tells the linker to
// accept duplicate definitions and silently bind the first. macOS never had
// the flag, so the same tree failed loudly there and linked-and-lied on linux.
// The flag is gone; this test keeps it gone, and keeps true the one-definition
// property that removing it relies on.

const usecache_test_root = os.join_path(os.vtmp_dir(),
	'builder_usecache_one_definition_${os.getpid()}')

// The probe exercises exactly the constructs whose generated code is emitted
// independently in more than one object of a cached build — the ones that
// decide whether duplicate definitions exist at all:
//   * a generic fn instantiated in both the cached module and the program (the
//     program TU re-emits generic bodies; the cached object has its own copy),
//   * a sumtype, whose per-variant casting fns are generated in every object
//     that touches it,
//   * a closure, whose runtime lives in a bundled builtin submodule that is
//     compiled into the program TU and must not also arrive from an object,
//   * a module-level const, defined in the cached object and referenced
//     `extern` by the program.
// If any of those ends up defined twice the link fails (that is the point);
// if the wrong copy were bound, the printed line changes.
const usecache_probe_files = {
	'probe/probe.v': "module probe

pub const tag = 'probe-const'

pub struct Wrapped {
pub:
	n int
}

pub type Boxed = Wrapped | string

pub fn twice[T](x T) T {
	return x + x
}

pub fn describe(b Boxed) string {
	return match b {
		Wrapped { 'w' + b.n.str() }
		string { 's' + b }
	}
}

pub fn adder(n int) fn (int) int {
	return fn [n] (x int) int {
		return x + n
	}
}
"
	'main.v':        "module main

import probe

fn main() {
	add := probe.adder(5)
	boxed := probe.Boxed(probe.Wrapped{ n: 3 })
	println('\${probe.tag}|\${probe.twice(7)}|\${probe.twice('ab')}|\${probe.describe(boxed)}|\${add(37)}')
}
"
}

const usecache_probe_expected = 'probe-const|14|abab|w3|42'

// run_v_in runs the V under test with a cache and a module root private to
// `dir`, so the probe starts from a cold cache and is neither disturbed by nor
// helped by the developer's real ~/.vmodules/.cache.
//
// os.execute rather than os.new_process + wait + slurp: `-dump-c-flags -`
// prints the whole flag list on stdout, and a redirected-stdio child that
// fills the pipe buffer blocks in write() while the parent blocks in wait().
// os.execute drains as it goes; it inherits this process's cwd, so the probe
// directory is entered here and restored afterwards.
fn run_v_in(dir string, out_name string, extra_args string) os.Result {
	saved_cwd := os.getwd()
	saved := {
		'VFLAGS':   os.getenv_opt('VFLAGS')
		'VMODULES': os.getenv_opt('VMODULES')
		'VCACHE':   os.getenv_opt('VCACHE')
	}
	defer {
		os.chdir(saved_cwd) or {}
		for name, value in saved {
			if value_set := value {
				os.setenv(name, value_set, true)
			} else {
				os.unsetenv(name)
			}
		}
	}
	os.unsetenv('VFLAGS')
	os.setenv('VMODULES', os.join_path(dir, 'vmodules'), true)
	os.setenv('VCACHE', os.join_path(dir, 'vmodules', '.cache'), true)
	os.chdir(dir) or { panic(err) }
	return os.execute('${os.quoted_path(@VEXE)} ${extra_args} -usecache -o ${out_name} main.v')
}

// One test function rather than three: a cold `-usecache` build of the probe
// costs a full build of builtin and friends, and the three things asserted
// here (cold link, flags, warm link) all want the same cache, so splitting
// them would pay that cost twice more for no extra signal.
fn test_usecache_links_exactly_one_definition_of_every_symbol() {
	os.rmdir_all(usecache_test_root) or {}
	os.mkdir_all(usecache_test_root) or { panic(err) }
	// real_path AFTER the directory exists: on macOS os.vtmp_dir() sits under
	// the /tmp -> /private/tmp symlink, and V derives a module's name from its
	// path, so a probe reached under one spelling and resolved under the other
	// is reported as a different module than the one `import probe` names.
	dir := os.real_path(usecache_test_root)
	defer {
		os.rmdir_all(dir) or {}
	}
	for rel_path, contents in usecache_probe_files {
		fpath := os.join_path(dir, rel_path)
		os.mkdir_all(os.dir(fpath)) or { panic(err) }
		os.write_file(fpath, contents) or { panic(err) }
	}

	// cold cache: every module object is built by this run
	cold := run_v_in(dir, 'probe_cold', '')
	assert cold.exit_code == 0, 'cold -usecache build failed:\n${cold.output}'
	cold_run := os.execute(os.quoted_path(os.join_path(dir, 'probe_cold')))
	assert cold_run.exit_code == 0, cold_run.output
	assert cold_run.output.trim_space() == usecache_probe_expected, cold_run.output

	// the link line itself must not ask the linker to tolerate duplicates
	$if !freebsd {
		// FreeBSD still passes `-Wl,--allow-multiple-definition` for every
		// build, not only cached ones; removing that needs its own measurement
		// on that platform, so do not assert about it here.
		flags := run_v_in(dir, 'probe_flags', '-dump-c-flags -')
		assert flags.exit_code == 0, flags.output
		assert !flags.output.contains('muldefs'), 'a -usecache link must not accept duplicate definitions:\n${flags.output}'
		assert !flags.output.contains('--allow-multiple-definition'), 'a -usecache link must not accept duplicate definitions:\n${flags.output}'
	}

	// warm cache: the module objects are served from the cache and linked
	// against a freshly generated program TU — the arrangement that turns a
	// duplicated definition into a link error (or, with muldefs, into a silent
	// wrong pick).
	warm := run_v_in(dir, 'probe_warm', '')
	assert warm.exit_code == 0, 'warm -usecache build failed:\n${warm.output}'
	assert !warm.output.contains('duplicate symbol'), warm.output
	assert !warm.output.contains('multiple definition'), warm.output
	warm_run := os.execute(os.quoted_path(os.join_path(dir, 'probe_warm')))
	assert warm_run.exit_code == 0, warm_run.output
	assert warm_run.output.trim_space() == usecache_probe_expected, warm_run.output
}
