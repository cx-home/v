module builder

import os
import hash
import time
import rand
import strings
import v.ast
import v.util
import v.pref
import v.vcache
import runtime

const crun_cache_format_version = 'crun_cache_v2'

pub fn (mut b Builder) rebuild_modules() {
	if !b.pref.use_cache || b.pref.build_mode == .build_module {
		return
	}
	if b.pref.check_only || b.pref.only_check_syntax {
		// Check-only flows should not trigger side-effecting cache rebuilds.
		// In the REPL import path that can compile imported `.c.v` modules
		// and surface irrelevant missing-header errors for declaration-only checks.
		return
	}
	all_files := b.parsed_files.map(it.path)
	$if trace_invalidations ? {
		eprintln('> rebuild_modules all_files: ${all_files}')
	}
	invalidations, snew_hashes := b.find_invalidated_modules_by_files(all_files)
	$if trace_invalidations ? {
		eprintln('> rebuild_modules invalidations: ${invalidations}')
	}
	mut stale_object_might_survive := false
	if invalidations.len > 0 {
		// The cached objects live under the cc-salted key (set_temporary_options
		// inside setup_ccompiler_options), which normally first appears at cc
		// time. This runs at parse end — set the salt NOW, or the stale-object
		// guard below computes an UNSALTED path, finds nothing there, declares
		// the failure harmless and saves the new hashes anyway (measured: the
		// guard looked in ac/… while the object sat in 87/…, resurrecting the
		// cx #151 poisoning it exists to prevent). setup_ccompiler_options is
		// re-entrant; validate_usecache_type_tables and cc() recompute the same
		// salt later (the cx-private#864 precedent).
		b.setup_ccompiler_options(b.pref.ccompiler)
		vexe := pref.vexe_path()
		for imp in invalidations {
			rc := b.v_build_module(vexe, imp)
			if rc != 0 {
				// CACHE-POISONING GUARD (cx #151): a failed module rebuild used to be
				// silently ignored while the new source hashes were ALREADY saved —
				// every later build then saw "hashes unchanged", skipped invalidation,
				// and linked the STALE cached object forever (until a manual cache
				// wipe). Observed as a permanent all-tests link failure
				// (_builtin__init_consts unresolved); an ABI-compatible variant would
				// be a silently WRONG binary. Aborting outright is too strict — the
				// invalidator sometimes names paths that are not real buildable
				// modules (e.g. a folder of standalone _test.v files) whose rebuild
				// has always failed harmlessly and which have no cached object to go
				// stale. The precise guard: a failure is only dangerous if a stale
				// object could still be SERVED — so remove the module's cached object;
				// once nothing stale can be linked, recording the new source hashes is
				// safe. Only if the stale object cannot be removed do we skip the hash
				// save (forcing re-detection + retry on the next run). A genuinely
				// needed-but-missing object is rebuilt on demand by
				// rebuild_cached_module, which fails loudly.
				stale_o := b.pref.cache_manager.mod_postfix_with_key2cpath(imp, '.o', imp)
				if os.exists(stale_o) {
					os.rm(stale_o) or { stale_object_might_survive = true }
					eprintln('warning: `v build-module ${imp}` failed (exit code ${rc}); removed its cached object so nothing stale can be linked.')
				} else {
					vcache.dlog('| Builder.' + @FN,
						'build-module failed for ${imp} (rc=${rc}); no cached object under this key — harmless (not a servable module)')
				}
			}
		}
	}
	if !stale_object_might_survive {
		// Persist the new source hashes only now — after every invalidated module was
		// rebuilt (or its stale object provably removed) — so a failed rebuild can
		// never poison the cache state.
		mut cm := b.source_hashes_cache_manager(all_files)
		cm.save('.hashes', 'all_files', snew_hashes) or {}
	}
}

// source_hashes_cache_manager keys the global source-hash record by the full
// build configuration as well as the file set. Keyed by file set alone, one
// configuration's save convinced every OTHER configuration of the same
// program that nothing changed — while their namespaces still held objects
// built from the old sources (measured cross-config staleness; the
// provenance manifests are the serve-time backstop, this keeps the
// invalidation fast path per-config so they rarely have to fire).
fn (b &Builder) source_hashes_cache_manager(all_files []string) vcache.CacheManager {
	mut opts := [b.pref.cache_manager.original_vopts]
	opts << all_files
	return vcache.new_cache_manager(opts)
}

pub fn (mut b Builder) find_invalidated_modules_by_files(all_files []string) ([]string, string) {
	util.timing_start('${@METHOD} source_hashing')
	mut new_hashes := map[string]string{}
	mut old_hashes := map[string]string{}
	mut sb_new_hashes := strings.new_builder(1024)

	mut cm := b.source_hashes_cache_manager(all_files)
	sold_hashes := cm.load('.hashes', 'all_files') or { ' ' }
	// eprintln(sold_hashes)
	sold_hashes_lines := sold_hashes.split('\n')
	for line in sold_hashes_lines {
		if line.len == 0 {
			continue
		}
		x := line.split(' ')
		chash := x[0]
		cpath := x[1]
		old_hashes[cpath] = chash
	}
	// eprintln('old_hashes: ${old_hashes}')
	for cpath in all_files {
		ccontent := util.read_file(cpath) or { '' }
		chash := hash.sum64_string(ccontent, 7).hex_full()
		new_hashes[cpath] = chash
		sb_new_hashes.write_string(chash)
		sb_new_hashes.write_u8(` `)
		sb_new_hashes.write_string(cpath)
		sb_new_hashes.write_u8(`\n`)
	}
	snew_hashes := sb_new_hashes.str()
	// eprintln('new_hashes: ${new_hashes}')
	// eprintln('> new_hashes != old_hashes: ' + ( old_hashes != new_hashes ).str())
	// eprintln(snew_hashes)
	// NOTE (cx #151): the new hashes are deliberately NOT saved here. The caller
	// saves them only after every invalidated module has been rebuilt
	// successfully; saving eagerly poisoned the cache on any rebuild failure.
	util.timing_measure('${@METHOD} source_hashing')

	mut invalidations := []string{}
	if new_hashes != old_hashes {
		util.timing_start('${@METHOD} rebuilding')
		// eprintln('> b.mod_invalidates_paths: ${b.mod_invalidates_paths}')
		// eprintln('> b.mod_invalidates_mods: ${b.mod_invalidates_mods}')
		// eprintln('> b.path_invalidates_mods: ${b.path_invalidates_mods}')
		$if trace_invalidations ? {
			for k, v in b.mod_invalidates_paths {
				mut m := map[string]bool{}
				for mm in b.mod_invalidates_mods[k] {
					m[mm] = true
				}
				eprintln('> module `${k}` invalidates: ${m.keys()}')
				for fpath in v {
					eprintln('         ${fpath}')
				}
			}
		}
		mut invalidated_paths := map[string]int{}
		mut invalidated_mod_paths := map[string]int{}
		for npath, nhash in new_hashes {
			if npath !in old_hashes {
				invalidated_paths[npath]++
				continue
			}
			if old_hashes[npath] != nhash {
				invalidated_paths[npath]++
				continue
			}
		}
		for opath, ohash in old_hashes {
			if opath !in new_hashes {
				invalidated_paths[opath]++
				continue
			}
			if new_hashes[opath] != ohash {
				invalidated_paths[opath]++
				continue
			}
		}
		$if trace_invalidations ? {
			eprintln('invalidated_paths: ${invalidated_paths}')
		}
		mut rebuild_everything := false
		for cycle := 0; true; cycle++ {
			$if trace_invalidations ? {
				eprintln('> cycle: ${cycle} | invalidated_paths: ${invalidated_paths}')
			}
			mut new_invalidated_paths := map[string]int{}
			for npath, _ in invalidated_paths {
				invalidated_mods := b.path_invalidates_mods[npath]
				if invalidated_mods == ['main'] {
					continue
				}
				if 'builtin' in invalidated_mods {
					// When `builtin` is invalid, there is no point in
					// extracting a finer grained dependency resolution
					// of the dependencies any more. Instead, just rebuild
					// every module.
					rebuild_everything = true
					break
				}
				for imod in invalidated_mods {
					if imod == 'main' {
						continue
					}
					for np in b.mod_invalidates_paths[imod] {
						new_invalidated_paths[np]++
					}
				}
				$if trace_invalidations ? {
					eprintln('> npath -> invalidated_mods | ${npath} -> ${invalidated_mods}')
				}
				mpath := os.dir(npath)
				invalidated_mod_paths[mpath]++
			}
			if rebuild_everything {
				break
			}
			if new_invalidated_paths.len == 0 {
				break
			}
			invalidated_paths = new_invalidated_paths.clone()
		}
		if rebuild_everything {
			invalidated_mod_paths = {}
			for npath, _ in new_hashes {
				mpath := os.dir(npath)
				pimods := b.path_invalidates_mods[npath]
				if pimods == ['main'] {
					continue
				}
				invalidated_mod_paths[mpath]++
			}
		}
		$if trace_invalidations ? {
			eprintln('invalidated_mod_paths: ${invalidated_mod_paths}')
			eprintln('rebuild_everything: ${rebuild_everything}')
		}
		if invalidated_mod_paths.len > 0 {
			impaths := invalidated_mod_paths.keys()
			for imp in impaths {
				invalidations << imp
			}
		}
		util.timing_measure('${@METHOD} rebuilding')
	}
	return invalidations, snew_hashes
}

fn (mut b Builder) v_build_module(vexe string, imp_path string) int {
	pwd := os.getwd()
	defer {
		os.chdir(pwd) or {}
	}
	// do run `v build-module x` always in main vfolder; x can be a relative path
	vroot := os.dir(vexe)
	os.chdir(vroot) or {}
	boptions := b.pref.build_options.join(' ')
	rebuild_cmd := '${os.quoted_path(vexe)} ${boptions} build-module ${os.quoted_path(imp_path)}'
	vcache.dlog('| Builder.' + @FN,
		'vexe: ${vexe} | imp_path: ${imp_path} | rebuild_cmd: ${rebuild_cmd}')
	$if trace_v_build_module ? {
		eprintln('> Builder.v_build_module: ${rebuild_cmd}')
	}
	// The exit status is the caller's problem now (cx #151): ignoring it while
	// the hashes were saved eagerly permanently poisoned the module cache.
	return os.system(rebuild_cmd)
}

// embed_file_content_hash returns the invalidation hash for one embedded-asset
// path; an unreadable file hashes to a constant that can never match a real
// content hash, so it always invalidates.
fn embed_file_content_hash(apath string) string {
	econtent := util.read_file(apath) or { return 'unreadable' }
	return hash.sum64_string(econtent, 7).hex_full()
}

// embeds_manifest serialises every checker-resolved $embed_file target of
// `parsed_files` as `<content-hash> <absolute-path>` lines. Saved next to a
// cached module object (see setup_output_name); verified by
// cached_module_embeds_fresh before a cached object is served.
fn embeds_manifest(parsed_files []&ast.File) string {
	mut seen := map[string]bool{}
	mut lines := []string{}
	for pf in parsed_files {
		for ea in pf.embedded_apaths {
			if seen[ea] {
				continue
			}
			seen[ea] = true
			lines << '${embed_file_content_hash(ea)} ${ea}'
		}
	}
	lines.sort()
	return lines.join('\n')
}

// cached_module_embeds_fresh reports whether every embedded asset recorded in
// the module's .embeds.txt manifest still has the content it was built with.
// The .v source hashes cannot see $embed_file targets, so without this check a
// cached object silently keeps serving stale embedded data after the asset
// changes. A missing manifest means the object was built by this compiler
// build with no embeds recorded (the compiler-identity salt namespaces away
// pre-manifest objects), so it is trivially fresh.
fn (mut b Builder) cached_module_embeds_fresh(imp_path string) bool {
	manifest := b.pref.cache_manager.mod_load(imp_path, '.embeds.txt', imp_path) or { return true }
	for line in manifest.split_into_lines() {
		if line == '' {
			continue
		}
		recorded := line.all_before(' ')
		apath := line.all_after(' ')
		if embed_file_content_hash(apath) != recorded {
			vcache.dlog('| Builder.' + @FN, 'stale embedded asset: ${apath} (module ${imp_path})')
			return false
		}
	}
	return true
}

// provenance_manifest_version versions the .srcs.txt format; a manifest with
// a different (or missing) version line is treated as absent, so format
// changes degrade to one rebuild instead of misreading old records.
const provenance_manifest_version = 'provenance_v1'

// provenance_manifest serialises, for a just-built module object, every input
// that shaped its bytes: an `o:` line binding the object file itself
// (size + content hash), an `f:` line per file dependency (every parsed .v
// source, every $tmpl template, every local #include/#insert C header), and
// an `e:` line per $env comptime read (hash of the resolved value). Written
// next to the cached object ONLY on build-module success; verified by
// cached_module_provenance_fresh before the object is ever served. This is
// what makes a cached object self-evidencing: without it, serve time trusted
// a global source-hash record that other configurations could update
// (cross-config staleness) and that bound the object to nothing (a planted
// or torn object was linked as-is).
fn (mut b Builder) provenance_manifest(obj_path string) string {
	mut seen := map[string]bool{}
	mut env_seen := map[string]bool{}
	mut file_deps := map[string]bool{}
	mut lines := []string{}
	for pf in b.parsed_files {
		if !pf.is_parse_text && !pf.is_template_text && !seen[pf.path] {
			seen[pf.path] = true
			file_deps[pf.path] = true
		}
		for tp in pf.template_paths {
			if !seen[tp] {
				seen[tp] = true
				file_deps[tp] = true
			}
		}
		for stmt in pf.stmts {
			// the crun dependency collector already resolves local
			// #include/#preinclude/#postinclude/#insert paths (and skips
			// system <...> headers); module provenance needs exactly that set
			b.collect_crun_stmt_dependencies(mut file_deps, stmt)
		}
		for name, val in pf.env_reads {
			if !env_seen[name] {
				env_seen[name] = true
				lines << 'e:${hash.sum64_string(val, 7).hex_full()} ${name}'
			}
		}
	}
	for fpath, _ in file_deps {
		lines << 'f:${embed_file_content_hash(fpath)} ${fpath}'
	}
	lines.sort()
	obj := os.read_bytes(obj_path) or { []u8{} }
	oline := 'o:${obj.len}:${hash.sum64(obj, 7).hex_full()}'
	return provenance_manifest_version + '\n' + oline + '\n' + lines.join('\n') + '\n'
}

// provenance_file_hash hashes a manifest file dependency, memoised so each
// file is read at most once per build no matter how many module manifests
// list it.
fn (mut b Builder) provenance_file_hash(fpath string) string {
	if cached := b.provenance_hash_memo[fpath] {
		return cached
	}
	h := embed_file_content_hash(fpath)
	b.provenance_hash_memo[fpath] = h
	return h
}

// cached_module_provenance_fresh reports whether the cached object at
// obj_path is still the product of the CURRENT inputs: its manifest must
// exist, bind these exact object bytes, and every recorded file dependency
// and $env value must hash to what was recorded at build time. A missing or
// mismatching manifest means the object cannot prove where it came from and
// is rebuilt — this closes cross-config staleness, template/header/env
// staleness, and planted or torn objects, in one serve-time check.
fn (mut b Builder) cached_module_provenance_fresh(imp_path string, obj_path string) bool {
	manifest := b.pref.cache_manager.mod_load(imp_path, '.srcs.txt', imp_path) or {
		vcache.dlog('| Builder.' + @FN, 'no provenance manifest for ${imp_path} — rebuilding')
		return false
	}
	lines := manifest.split_into_lines()
	if lines.len == 0 || lines[0] != provenance_manifest_version {
		vcache.dlog('| Builder.' + @FN, 'unknown manifest version for ${imp_path} — rebuilding')
		return false
	}
	for line in lines[1..] {
		if line.len < 2 {
			continue
		}
		rest := line[2..]
		match line[..2] {
			'o:' {
				parts := rest.split(':')
				if parts.len != 2 {
					return false
				}
				obj := os.read_bytes(obj_path) or { return false }
				if obj.len.str() != parts[0] || hash.sum64(obj, 7).hex_full() != parts[1] {
					vcache.dlog('| Builder.' + @FN, 'object bytes do not match manifest binding: ${obj_path}')
					return false
				}
			}
			'f:' {
				recorded := rest.all_before(' ')
				fpath := rest.all_after(' ')
				if b.provenance_file_hash(fpath) != recorded {
					vcache.dlog('| Builder.' + @FN, 'stale file dependency: ${fpath} (module ${imp_path})')
					return false
				}
			}
			'e:' {
				recorded := rest.all_before(' ')
				name := rest.all_after(' ')
				if hash.sum64_string(os.getenv(name), 7).hex_full() != recorded {
					vcache.dlog('| Builder.' + @FN, 'stale \$env value: ${name} (module ${imp_path})')
					return false
				}
			}
			else {
				// unknown row kind from a future format — fail closed
				return false
			}
		}
	}
	return true
}

// publish_built_module_object finalises a successful build-module compile:
// it writes the provenance manifest binding the just-produced object bytes,
// then atomically renames the temporary object into its final cache path.
// The rename is the commit point — a concurrent consumer either sees the old
// complete object (whose manifest check decides its fate) or the new
// complete one, never a partial write; and no object becomes servable before
// its manifest exists.
fn (mut b Builder) publish_built_module_object() {
	if b.pref.build_mode != .build_module || b.build_module_final_o == '' {
		return
	}
	built := b.pref.out_name
	if !os.exists(built) {
		return
	}
	manifest := b.provenance_manifest(built)
	b.pref.cache_manager.mod_save(b.pref.path, '.srcs.txt', b.pref.path, manifest) or { panic(err) }
	if built != b.build_module_final_o {
		os.mv(built, b.build_module_final_o) or { panic(err) }
	}
}

fn (mut b Builder) rebuild_cached_module(vexe string, imp_path string) string {
	mut existing := ''
	if res := b.pref.cache_manager.mod_exists(imp_path, '.o', imp_path) {
		existing = res
	}
	if existing != '' && b.cached_module_embeds_fresh(imp_path)
		&& b.cached_module_provenance_fresh(imp_path, existing) {
		return existing
	}
	if b.pref.is_verbose {
		if existing == '' {
			println('Cached ${imp_path} .o file not found... Building .o file for ${imp_path}')
		} else {
			println('Cached ${imp_path} .o file is stale (embedded assets or provenance)... Rebuilding .o file for ${imp_path}')
		}
	}
	rc := b.v_build_module(vexe, imp_path)
	if rc != 0 && existing != '' {
		// A failed rebuild must not keep serving the stale object (the same
		// poisoning class as the eager-hash-save bug, cx #151).
		os.rm(existing) or {}
	}
	rebuilt_o := b.pref.cache_manager.mod_exists(imp_path, '.o', imp_path) or {
		panic('could not rebuild cache module for ${imp_path}, error: ${err.msg()}')
	}
	return rebuilt_o
}

// usecache_candidate_modules enumerates every module a -usecache build would
// link as a cached layer object, as (module name, module path) pairs, in the
// same order and under the same guards handle_usecache links them. Factored so
// the pre-cgen type-table validation (cx-private#864) and the cc-stage linking
// agree on the candidate set by construction.
fn (mut b Builder) usecache_candidate_modules() ([]string, []string) {
	mut mods := []string{}
	mut paths := []string{}
	for ast_file in b.parsed_files {
		// Cache the test's own non-main modules. Apply the same guards as the import
		// loop below: builtin (and its parts: strconv/strings/math.bits/...) are already
		// inside builtin.o, and a module already queued must not be built again — without
		// these guards a test build caches builtin a SECOND time via its absolute path
		// (a086..module.builtin.o AND 7c16..module.<abspath>.builtin.o), linking both and
		// duplicating every builtin symbol (~9000 "duplicate symbol" errors at link).
		if b.pref.is_test && ast_file.mod.name != 'main' && ast_file.mod.name != 'help'
			&& !util.module_is_builtin(ast_file.mod.name) && ast_file.mod.name !in mods
			&& !util.should_bundle_module(ast_file.mod.name) {
			imp_path := b.find_module_path(ast_file.mod.name, ast_file.path) or {
				verror('cannot import module "${ast_file.mod.name}" (not found)')
				break
			}
			mods << ast_file.mod.name
			paths << imp_path
		}
		for imp_stmt in ast_file.imports {
			imp := imp_stmt.mod
			// strconv is already imported inside builtin, so skip generating its object file
			// TODO: in case we have other modules with the same name, make sure they are vlib
			// is this even doing anything?
			if util.module_is_builtin(imp) {
				continue
			}
			if imp in mods {
				continue
			}
			if util.should_bundle_module(imp) {
				continue
			}
			// The problem is cmd/v is in module main and imports
			// the relative module named help, which is built as cmd.v.help not help
			// currently this got this working by building into main, see ast.FnDecl in cgen
			if imp == 'help' {
				continue
			}
			imp_path := b.find_module_path(imp, ast_file.path) or {
				verror('cannot import module "${imp}" (not found)')
				break
			}
			mods << imp
			paths << imp_path
		}
	}
	return mods, paths
}

// validate_usecache_type_tables (cx-private#864) — runs AFTER the checker and
// BEFORE cgen. A cached module layer is compiled in its OWN type universe
// (module + its deps); this program's universe (all modules + the test file's
// extra imports) can assign the same types DIFFERENT ids. Both objects carry
// generated helpers that dispatch on the numeric `_typ` (sumtype str/free/
// compare) and construction sites that write it, and values cross the object
// boundary freely — so any disagreement is a silent type-pun: the measured
// failure was every cx.ProgramNode variant differing (main 139-181 vs layer
// 137-155) with a SIGSEGV in a generated walker as the visible tip.
//
// The rule is prefix agreement: every (idx, name) the layer recorded must be
// EXACTLY this build's (idx, name). Any deviation puts the module on
// pref.usecache_invalid_mods: its .o is not linked and cgen emits its bodies
// inline — correctness always, the compile-time win only where it is sound.
// A layer without a fingerprint (predating this check) is rebuilt once to
// produce one; if it still has none it is invalidated.
pub fn (mut b Builder) validate_usecache_type_tables() {
	if !b.pref.use_cache || b.pref.build_mode == .build_module {
		return
	}
	// The vcache key carries a cc-derived salt (set_temporary_options inside
	// setup_ccompiler_options) that normally first appears at cc time — this
	// pass runs pre-cgen, so set it NOW or every lookup below lands in an
	// unsalted bucket and misses (measured: the first draft of this fn rm'd
	// and rebuilt every layer into one bucket and then panicked looking in
	// the other). setup_ccompiler_options is re-entrant; cc() recomputes the
	// same salt later.
	b.setup_ccompiler_options(b.pref.ccompiler)
	vexe := pref.vexe_path()
	mods, paths := b.usecache_candidate_modules()
	for i, imp_path in paths {
		b.rebuild_cached_module(vexe, imp_path)
		mut fp := b.pref.cache_manager.mod_load(imp_path, '.types.txt', imp_path) or { '' }
		if fp == '' {
			// pre-fingerprint cache entry: rebuild once so the layer records one.
			if stale := b.pref.cache_manager.mod_exists(imp_path, '.o', imp_path) {
				os.rm(stale) or {}
			}
			b.rebuild_cached_module(vexe, imp_path)
			fp = b.pref.cache_manager.mod_load(imp_path, '.types.txt', imp_path) or { '' }
		}
		mut ok := fp != ''
		if ok {
			for line in fp.split_into_lines() {
				ci := line.index(':') or { continue }
				idx := line[..ci].int()
				name := line[ci + 1..]
				if b.table.type_idxs[name] or { -1 } != idx {
					ok = false
					$if trace_usecache_types ? {
						eprintln('> usecache type-table mismatch in ${mods[i]}: layer ${idx}:${name} vs program ${b.table.type_idxs[name] or { -1 }}')
					}
					break
				}
			}
		}
		if !ok {
			b.pref.usecache_invalid_mods << mods[i]
			if b.pref.is_verbose {
				eprintln('> -usecache: module ${mods[i]} cached layer type table does not match this build — emitting it inline (cx-private#864)')
			}
		}
	}
}

fn (mut b Builder) handle_usecache(vexe string) {
	if !b.pref.use_cache || b.pref.build_mode == .build_module {
		return
	}
	mut libs := []string{} // builtin.o os.o http.o etc
	builtin_obj_path := b.rebuild_cached_module(vexe, 'vlib/builtin')
	libs << builtin_obj_path
	mods, paths := b.usecache_candidate_modules()
	for i, imp_path in paths {
		// cx-private#864: a module whose cached layer failed type-table
		// validation is emitted inline by cgen — linking its .o too would
		// both duplicate symbols and re-introduce the type-pun.
		if mods[i] in b.pref.usecache_invalid_mods {
			continue
		}
		obj_path := b.rebuild_cached_module(vexe, imp_path)
		libs << obj_path
	}
	b.ccoptions.post_args << libs
}

pub fn (mut b Builder) should_rebuild() bool {
	mut exe_name := b.pref.out_name
	$if windows {
		exe_name += '.exe'
	}
	if !os.is_file(exe_name) {
		return true
	}
	if !b.pref.is_crun {
		return true
	}
	mut v_program_files := []string{}
	is_file := os.is_file(b.pref.path)
	is_dir := os.is_dir(b.pref.path)
	if is_file {
		v_program_files << b.pref.path
	} else if is_dir {
		v_program_files << b.v_files_from_dir(b.pref.path)
	}
	v_program_files.sort() // ensure stable keys for the dependencies cache
	b.crun_cache_keys = v_program_files
	b.crun_cache_keys << exe_name
	// just check the timestamps for now:
	exe_stamp := os.file_last_mod_unix(exe_name)
	source_stamp := most_recent_timestamp(v_program_files)
	if exe_stamp <= source_stamp {
		return true
	}
	////////////////////////////////////////////////////////////////////////////
	// The timestamps for the top level files were found ok,
	// however we want to *also* make sure that a full rebuild will be done
	// if any of the dependencies (if we know them) are changed.
	mut cm := vcache.new_cache_manager(b.crun_cache_keys)
	// always rebuild, when the compilation options changed between 2 sequential cruns:
	sbuild_options := cm.load('.build_options', '.crun') or { return true }
	if sbuild_options != b.crun_build_options_signature() {
		return true
	}
	sdependencies := cm.load('.dependencies', '.crun') or {
		// empty/wiped out cache, we do not know what the dependencies are, so just
		// rebuild, which will fill in the dependencies cache for the next crun
		return true
	}
	dependencies := sdependencies.split('\n').filter(it != '')
	for dependency in dependencies {
		if !os.is_file(dependency) {
			return true
		}
		if os.file_last_mod_unix(dependency) >= exe_stamp {
			return true
		}
	}
	return false
}

fn most_recent_timestamp(files []string) i64 {
	mut res := i64(0)
	for f in files {
		f_stamp := os.file_last_mod_unix(f)
		if res <= f_stamp {
			res = f_stamp
		}
	}
	return res
}

pub fn (mut b Builder) rebuild(backend_cb FnBackend) {
	mut sw := time.new_stopwatch()
	backend_cb(mut b)
	if b.pref.is_crun {
		// save the dependencies after the first compilation, they will be used for subsequent ones:
		mut cm := vcache.new_cache_manager(b.crun_cache_keys)
		dependency_files := b.crun_dependency_files()
		cm.save('.dependencies', '.crun', dependency_files.join('\n')) or {}
		cm.save('.build_options', '.crun', b.crun_build_options_signature()) or {}
	}
	mut timers := util.get_timers()
	timers.show_remaining()
	if b.pref.is_stats {
		compilation_time_micros := 1 + sw.elapsed().microseconds()
		scompilation_time_ms := util.bold('${f64(compilation_time_micros) / 1000.0:6.3f}')
		mut all_v_source_lines, mut all_v_source_bytes, mut all_v_source_tokens := 0, 0, 0
		mut all_v_top_stmts, mut all_non_vlib_top_stmts, mut all_main_top_stmts := 0, 0, 0
		for pf in b.parsed_files {
			all_v_source_lines += pf.nr_lines
			all_v_source_bytes += pf.nr_bytes
			all_v_source_tokens += pf.nr_tokens
			all_v_top_stmts += pf.stmts.len
			if !pf.path.contains('vlib/') {
				all_non_vlib_top_stmts += pf.stmts.len
			}
			if pf.mod.name == 'main' {
				all_main_top_stmts += pf.stmts.len
			}
		}
		mut sall_top_stmts := all_v_top_stmts.str()
		mut sall_non_vlib_top_stmts := all_non_vlib_top_stmts.str()
		mut sall_main_top_stmts := all_main_top_stmts.str()
		mut sall_v_source_lines := all_v_source_lines.str()
		mut sall_v_source_bytes := all_v_source_bytes.str()
		mut sall_v_source_tokens := all_v_source_tokens.str()
		mut sall_v_types := b.table.type_symbols.len.str()
		mut sall_v_modules := b.table.modules.len.str()
		mut sall_v_files := b.parsed_files.len.str()
		sall_v_source_lines = util.bold('${sall_v_source_lines:10s}')
		sall_v_source_bytes = util.bold('${sall_v_source_bytes:10s}')
		sall_v_source_tokens = util.bold('${sall_v_source_tokens:10s}')
		sall_v_types = util.bold('${sall_v_types:5s}')
		sall_v_modules = util.bold('${sall_v_modules:5s}')
		sall_v_files = util.bold('${sall_v_files:5s}')
		sall_top_stmts = util.bold('${sall_top_stmts:5s}')
		sall_non_vlib_top_stmts = util.bold('${sall_non_vlib_top_stmts:5s}')
		sall_main_top_stmts = util.bold('${sall_main_top_stmts:5s}')
		println('        V  source  code size: ${sall_v_source_lines} lines, ${sall_v_source_tokens} tokens, ${sall_v_source_bytes} bytes, ${sall_v_types} types, ${sall_v_modules} modules, ${sall_v_files} files, ${sall_top_stmts} tl_stmts, ${sall_non_vlib_top_stmts} non_vlib_tl_stmts, ${sall_main_top_stmts} main_tl_stmts')
		//
		mut slines := b.stats_lines.str()
		mut sbytes := b.stats_bytes.str()
		slines = util.bold('${slines:10s}')
		sbytes = util.bold('${sbytes:10s}')
		println('generated  target  code size: ${slines} lines, ${sbytes} bytes')
		//
		vlines_per_second := int(1_000_000.0 * f64(all_v_source_lines) / f64(compilation_time_micros))
		svlines_per_second := util.bold(vlines_per_second.str())
		used_cgen_threads := if b.pref.no_parallel { 1 } else { runtime.nr_jobs() }
		println('compilation took: ${scompilation_time_ms} ms, compilation speed: ${svlines_per_second} vlines/s, cgen threads: ${used_cgen_threads}')
	}
}

fn (b &Builder) crun_build_options_signature() string {
	mut parts := []string{cap: b.pref.build_options.len + 1}
	parts << crun_cache_format_version
	parts << b.pref.build_options
	return parts.join('\n')
}

fn add_existing_crun_dependency(mut dependencies map[string]bool, path string) {
	if path == '' {
		return
	}
	real_path := os.real_path(path)
	if os.is_file(real_path) {
		dependencies[real_path] = true
	}
}

fn (b &Builder) crun_hash_stmt_dependency_path(node ast.HashStmt) string {
	match node.kind {
		'include', 'preinclude', 'postinclude' {
			if node.main.starts_with('<') && node.main.ends_with('>') {
				return ''
			}
			mut path := node.main.trim('"')
			if !os.is_abs_path(path) {
				path = os.join_path(os.dir(node.source_file), path)
			}
			return path
		}
		'insert' {
			mut path := node.main.trim('"')
			if !os.is_abs_path(path) {
				path = os.join_path(os.dir(node.source_file), path)
			}
			return path
		}
		else {
			return ''
		}
	}
}

fn (b &Builder) collect_crun_stmt_dependencies(mut dependencies map[string]bool, stmt ast.Stmt) {
	match stmt {
		ast.HashStmt {
			add_existing_crun_dependency(mut dependencies, b.crun_hash_stmt_dependency_path(stmt))
		}
		ast.ExprStmt {
			if stmt.expr is ast.IfExpr && stmt.expr.is_comptime {
				b.collect_crun_if_expr_dependencies(mut dependencies, stmt.expr)
			}
		}
		else {}
	}
}

fn (b &Builder) collect_crun_if_expr_dependencies(mut dependencies map[string]bool, expr ast.IfExpr) {
	for branch in expr.branches {
		for stmt in branch.stmts {
			b.collect_crun_stmt_dependencies(mut dependencies, stmt)
		}
	}
}

fn (mut b Builder) crun_dependency_files() []string {
	mut dependencies := map[string]bool{}
	for file in b.parsed_files {
		add_existing_crun_dependency(mut dependencies, file.path)
		for template_path in file.template_paths {
			add_existing_crun_dependency(mut dependencies, template_path)
		}
		for embedded_file in file.embedded_files {
			add_existing_crun_dependency(mut dependencies, embedded_file.apath)
		}
		for stmt in file.stmts {
			b.collect_crun_stmt_dependencies(mut dependencies, stmt)
		}
	}
	for cflag in b.get_os_cflags() {
		value := cflag.eval() or { continue }
		add_existing_crun_dependency(mut dependencies, value)
	}
	mut files := dependencies.keys()
	files.sort()
	return files
}

pub fn (mut b Builder) get_vtmp_filename(base_file_name string, postfix string) string {
	vtmp := os.vtmp_dir()
	mut uniq := ''
	if !b.pref.reuse_tmpc {
		uniq = '.${rand.ulid()}'
	}
	fname := sanitized_vtmp_basename(base_file_name) + '${uniq}${postfix}'
	return os.real_path(os.join_path(vtmp, fname))
}

fn sanitized_vtmp_basename(base_file_name string) string {
	name := os.file_name(os.real_path(base_file_name))
	mut sanitized := strings.new_builder(name.len)
	for ch in name {
		if ch >= 128 || (ch >= `0` && ch <= `9`) || (ch >= `A` && ch <= `Z`)
			|| (ch >= `a` && ch <= `z`) || ch in [`-`, `.`, `_`] {
			sanitized.write_u8(ch)
		} else {
			sanitized.write_u8(`_`)
		}
	}
	result := sanitized.str()
	if result in ['', '.', '..'] {
		return 'vtmp'
	}
	return result
}
