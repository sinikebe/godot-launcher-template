extends SceneTree
## Headless tests for the launcher's changelog and staged-pack logic.
##
## Run from the project root, with a throwaway HOME so user:// is not yours:
##
##     HOME=$(mktemp -d) godot --headless --path . --import
##     HOME=$(mktemp -d) godot --headless --path . --script ci/tests/run_gd_tests.gd
##
## It exits non-zero when anything fails. Do NOT trust the exit code of a plain
## boot to mean "no script errors" (issue #71); this script counts its own.
##
## Why a script and not an addon: it needs no new dependency in a template that
## is copied into games, and ci/tests/.gdignore keeps it out of every export.
## It reads the real autoloads (UpdateService, BuildInfo), so it covers the code
## the app runs, not a copy of it.

var _fails := 0
var _checks := 0
var _us: Node
var _bi: Node


func check(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("FAIL  " + what)


func eq(got: Variant, want: Variant, what: String) -> void:
	_checks += 1
	if typeof(got) != typeof(want) or got != want:
		_fails += 1
		print("FAIL  %s\n      got : %s\n      want: %s" % [what, var_to_str(got), var_to_str(want)])


func _initialize() -> void:
	# Expected strings are English. A game that ships a translation of the launcher
	# must not make these fail on a machine set to another language.
	TranslationServer.set_locale("en")
	_us = root.get_node_or_null("UpdateService")
	_bi = root.get_node_or_null("BuildInfo")
	if _us == null or _bi == null:
		print("FAIL  autoloads missing: run with --path at the project root")
		quit(2)
		return

	# These tests write user://update_state.json, user://changelog.json and
	# user://content/. Refuse to run over somebody's real data.
	for path: String in [_bi.STATE_PATH, _us.CHANGELOG_CACHE_PATH]:
		if FileAccess.file_exists(path):
			print("REFUSING: %s exists. Run with HOME=$(mktemp -d) so user:// is scratch." % path)
			quit(2)
			return

	_test_format_entries()
	_test_full_changelog()
	_test_pending_and_has_notes()
	_test_more_changelog()
	_test_mount_staged_content()
	_test_mount_edge_cases()
	_test_checksum_at_mount()
	_test_staging_sweep()
	_test_too_new_manifest_is_not_cached()
	_cleanup()

	print("%d checks, %d failed" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _entry(version: int, changes: Variant, name := "") -> Dictionary:
	return {"content_version": version, "version_name": name if name != "" else "1.%d" % version,
			"released_at": "t", "changes": changes}


func _reset_build(installed: int, own: Array = []) -> void:
	_bi.base_content_version = installed
	_bi.content_version = installed
	_bi.version_name = "own"
	_bi.built_at = "built"
	_bi.own_changes = own
	_us.manifest = {}
	if FileAccess.file_exists(_us.CHANGELOG_CACHE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_us.CHANGELOG_CACHE_PATH))


func _versions(entries: Array) -> Array:
	return entries.map(func(e: Dictionary) -> int: return int(e.get("content_version", -99)))


# ---------------------------------------------------------------------------
# UpdateService._format_entries
# ---------------------------------------------------------------------------

func _test_format_entries() -> void:
	_reset_build(2)
	var f := func(entries: Array, max_lines: int, mark: bool) -> String:
		return _us._format_entries(entries, max_lines, mark)

	eq(f.call([], 10, false), "", "no entries renders nothing")

	# entries with nothing to say are skipped, whatever "nothing" looks like
	var empties := [_entry(3, []), {"content_version": 4, "version_name": "x"},
			_entry(5, "not an array"), _entry(6, null)]
	eq(f.call(empties, 10, false), "", "entries without changes render nothing")

	var one: String = f.call([_entry(3, ["a", "b"], "1.3")], 10, false)
	eq(one, "v1.3  ·  build 3\n  •  a\n  •  b", "one entry: heading, then bullets")

	var two: String = f.call([_entry(3, ["a"], "1.3"), _entry(2, ["b"], "1.2")], 10, false)
	eq(two, "v1.3  ·  build 3\n  •  a\n\nv1.2  ·  build 2\n  •  b",
			"entries are separated by one blank line, in the order given")

	var mixed: String = f.call([_entry(4, []), _entry(3, ["a"], "1.3")], 10, false)
	eq(mixed, "v1.3  ·  build 3\n  •  a", "a skipped entry leaves no stray blank line")

	eq(f.call([_entry(3, [7, true], "1.3")], 10, false), "v1.3  ·  build 3\n  •  7\n  •  true",
			"non-string changes are stringified")
	eq(f.call([{"content_version": 3, "changes": ["a"]}], 10, false), "v?  ·  build 3\n  •  a",
			"a missing version_name shows as ?")

	# the running build is marked only when asked, and only that entry
	var marked: String = f.call([_entry(3, ["a"], "1.3"), _entry(2, ["b"], "1.2")], 10, true)
	eq(marked, "v1.3  ·  build 3\n  •  a\n\nv1.2  ·  build 2     <- installed\n  •  b",
			"mark_installed flags the running build (content version 2) and nothing else")
	check(not "<- installed" in two, "mark_installed false marks nothing")

	# the cap counts lines of text, headings included, and says what it dropped
	var a := _entry(3, ["a1", "a2"], "1.3")
	var b := _entry(2, ["b1", "b2"], "1.2")
	eq(f.call([a, b], 3, false), "v1.3  ·  build 3\n  •  a1\n  •  a2\n\n…and 2 more changes.",
			"cap reached at an entry boundary drops the next entry whole, and counts its changes")
	eq(f.call([a, b], 2, false), "v1.3  ·  build 3\n  •  a1\n\n…and 3 more changes.",
			"cap reached mid-entry drops the rest of it plus every later entry")
	eq(f.call([a], 2, false), "v1.3  ·  build 3\n  •  a1\n\n…and 1 more change.",
			"exactly one dropped change uses the singular")
	eq(f.call([a, b], 100, false).contains("more change"), false, "under the cap nothing is reported dropped")
	# a heading is never drawn without room for it, and never left bare
	eq(f.call([a, b], 1, false), "v1.3  ·  build 3\n\n…and 4 more changes.",
			"a heading alone fits max_lines=1; both entries' changes are counted as dropped")


# ---------------------------------------------------------------------------
# UpdateService.full_changelog
# ---------------------------------------------------------------------------

func _test_full_changelog() -> void:
	_reset_build(2)
	eq(_us.full_changelog(), [], "nothing known and no own notes: empty")

	# the manifest's history, newest first whatever order it arrives in
	_us.manifest = {"changelog": [_entry(1, ["x"]), _entry(3, ["y"]), _entry(2, ["z"])]}
	eq(_versions(_us.full_changelog()), [3, 2, 1], "sorted newest first")

	# a version seen twice keeps the first entry
	_us.manifest = {"changelog": [_entry(3, ["first"]), _entry(3, ["second"]), _entry(2, ["z"])]}
	var dedup: Array = _us.full_changelog()
	eq(_versions(dedup), [3, 2], "duplicate content_version collapsed")
	eq(dedup[0]["changes"], ["first"], "the first of a duplicate pair wins")

	# junk inside the list is ignored
	_us.manifest = {"changelog": ["junk", 7, null, _entry(3, ["y"])]}
	eq(_versions(_us.full_changelog()), [3], "non-dictionary items skipped")

	# own-build fallback: added when the history lacks the running build
	_reset_build(2, ["own change"])
	_us.manifest = {"changelog": [_entry(3, ["y"])]}
	var with_own: Array = _us.full_changelog()
	eq(_versions(with_own), [3, 2], "own build appended and sorted into place")
	eq(with_own[1], {"content_version": 2, "version_name": "own", "released_at": "built",
			"changes": ["own change"]}, "own-build entry is built from BuildInfo")

	# ...not when the history already has it, and not when it has nothing to say
	_us.manifest = {"changelog": [_entry(3, ["y"]), _entry(2, ["from manifest"])]}
	var has_own: Array = _us.full_changelog()
	eq(_versions(has_own), [3, 2], "own build not added twice")
	eq(has_own[1]["changes"], ["from manifest"], "the manifest's entry for the running build wins")
	_reset_build(2, [])
	_us.manifest = {"changelog": [_entry(3, ["y"])]}
	eq(_versions(_us.full_changelog()), [3], "no own notes: no own entry")

	# fresh install, no network: the own notes alone
	_reset_build(2, ["only mine"])
	eq(_versions(_us.full_changelog()), [2], "offline and uncached: just this build's notes")

	# the cache stands in for the manifest, but never overrides a non-empty one
	_reset_build(2)
	var f := FileAccess.open(_us.CHANGELOG_CACHE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({"changelog": [_entry(5, ["cached"]), _entry(4, ["cached"])]}))
	f.close()
	eq(_versions(_us.full_changelog()), [5, 4], "empty manifest falls back to the cached history")
	_us.manifest = {"changelog": [_entry(9, ["live"])]}
	eq(_versions(_us.full_changelog()), [9], "a non-empty manifest ignores the cache")
	_us.manifest = {"changelog": []}
	eq(_versions(_us.full_changelog()), [5, 4], "an empty manifest changelog still uses the cache")
	_us.manifest = {"changelog": "oops"}
	eq(_versions(_us.full_changelog()), [5, 4], "a malformed manifest changelog uses the cache")

	# a corrupt cache is "nothing", not a crash. Godot logs an ERROR line for the
	# JSON it cannot parse; that is the case under test, not a failure.
	var g := FileAccess.open(_us.CHANGELOG_CACHE_PATH, FileAccess.WRITE)
	g.store_string("{not json")
	g.close()
	_us.manifest = {}
	eq(_us.full_changelog(), [], "unreadable cache is treated as empty")
	g = FileAccess.open(_us.CHANGELOG_CACHE_PATH, FileAccess.WRITE)
	g.store_string(JSON.stringify({"changelog": "nope"}))
	g.close()
	eq(_us.full_changelog(), [], "cache without a changelog array is treated as empty")


# ---------------------------------------------------------------------------
# pending_changelog / has_notes / the text wrappers
# ---------------------------------------------------------------------------

func _test_pending_and_has_notes() -> void:
	_reset_build(2)
	_us.manifest = {"changelog": [_entry(4, ["d"]), _entry(3, ["c"]), _entry(2, ["b"]), _entry(1, ["a"])]}
	eq(_versions(_us.pending_changelog()), [4, 3], "pending = strictly newer than the installed content version")
	_us.manifest = {"changelog": "nope"}
	eq(_us.pending_changelog(), [], "malformed changelog: nothing pending")

	_reset_build(2)
	check(not _us.has_notes(), "no history: no notes")
	_us.manifest = {"changelog": [_entry(3, []), _entry(2, null)]}
	check(not _us.has_notes(), "a history of empty entries has no notes")
	eq(_us.history_text(), "", "...and history_text agrees: it renders nothing")
	_us.manifest = {"changelog": [_entry(3, []), _entry(2, ["real"])]}
	check(_us.has_notes(), "one entry with changes means notes")
	check(_us.history_text() != "", "...and history_text agrees: it renders something")
	check("<- installed" in _us.history_text(), "history_text marks the running build")

	_us.manifest = {"changelog": [_entry(4, ["d"]), _entry(2, ["b"])]}
	var pending: String = _us.pending_notes_text()
	check("build 4" in pending and not "build 2" in pending, "pending_notes_text shows only what is on offer")
	check(not "<- installed" in pending, "pending_notes_text marks nothing installed")



func _test_more_changelog() -> void:
	# a mounted pack: the live content version is ahead of the binary's own
	_reset_build(5)
	_bi.content_version = 7
	_us.manifest = {"changelog": [_entry(8, ["new"]), _entry(7, ["live"]), _entry(6, ["mid"]), _entry(5, ["old"])]}
	eq(_versions(_us.pending_changelog()), [8], "pending is measured from the live content version, not the binary's")
	var h: String = _us.history_text()
	check("build 7     <- installed" in h, "the installed mark follows the live content version")
	check(not "build 5     <- installed" in h, "...and not the binary's")

	# entries that are not what the pipeline writes
	_reset_build(2)
	_us.manifest = {"changelog": ["junk", 7, null, {"changes": ["no version"]}, _entry(3, ["ok"])]}
	eq(_versions(_us.pending_changelog()), [3], "pending skips junk and an entry with no content_version")
	eq(_us._format_entries([{"changes": ["a"]}], 10, false), "v?  ·  build 0\n  •  a",
			"an entry with no version or name still renders, as build 0")
	_us.manifest = {"changelog": [{"changes": ["a"]}, _entry(0, ["b"])]}
	eq(_us.full_changelog().size(), 2, "an entry with no content_version is not the same as version 0")
	_us.manifest = {"changelog": [_entry(4, []), _entry(3, ["x"]), _entry(2, [])]}
	check(_us.has_notes(), "has_notes looks past the first and last entries")

	# the cache written by a check is what an offline launch reads
	_reset_build(2)
	_us.manifest = {"changelog": [_entry(6, ["a"]), _entry(5, ["b"])]}
	_us._cache_changelog()
	_us.manifest = {}
	eq(_versions(_us.full_changelog()), [6, 5], "the last check's changelog is cached and read back with no network")
	_us.manifest = {"changelog": []}
	_us._cache_changelog()
	_us.manifest = {}
	eq(_versions(_us.full_changelog()), [6, 5], "an empty changelog never overwrites a good cache")

# ---------------------------------------------------------------------------
# BuildInfo._mount_staged_content
# ---------------------------------------------------------------------------

const MARKER := "res://ci_gd_test_marker.txt"


func _make_pack(version: int) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(_bi.CONTENT_DIR)
	var src := "user://marker-%d.txt" % version
	var f := FileAccess.open(src, FileAccess.WRITE)
	f.store_string("pack %d" % version)
	f.close()
	var path: String = _bi.CONTENT_DIR.path_join("content-%d.pck" % version)
	var packer := PCKPacker.new()
	packer.pck_start(path)
	packer.add_file(MARKER, ProjectSettings.globalize_path(src))
	var over := "user://override-%d.json" % version
	var of := FileAccess.open(over, FileAccess.WRITE)
	of.store_string("pack %d" % version)
	of.close()
	packer.add_file("res://version.json", ProjectSettings.globalize_path(over))
	packer.flush()
	return {"path": path, "size": FileAccess.open(path, FileAccess.READ).get_length()}


func _stage(version: int, branch := "", with_pack := true, size_delta := 0, size_key := true) -> Dictionary:
	var pack := _make_pack(version) if with_pack else {"path": _bi.CONTENT_DIR.path_join("content-%d.pck" % version), "size": 0}
	var state := {"content_version": version, "pack_path": pack["path"], "branch": branch}
	if size_key:
		state["size"] = int(pack["size"]) + size_delta
	_bi.write_state(state)
	return pack


func _mount_from_clean(installed: int, branch := "") -> void:
	_reset_build(installed)
	_bi.release_branch = branch
	_bi.pack_error = ""
	_bi.active_pack_path = ""
	_bi._mount_staged_content()


func _wipe() -> void:
	_bi.clear_state()
	var dir := DirAccess.open(_bi.CONTENT_DIR)
	if dir != null:
		for file in dir.get_files():
			dir.remove(file)


func _test_mount_staged_content() -> void:
	_wipe()

	# nothing staged: nothing mounted, nothing broken
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "no state: content version stays the binary's")
	eq(_bi.active_pack_path, "", "no state: no pack mounted")
	eq(_bi.pack_error, "", "no state: no error")

	# state pointing at a pack that is gone
	_stage(9, "", false)
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "missing pack file: not mounted")
	check(_bi.read_state().is_empty(), "missing pack file: state cleared")

	# rollback guard: at or below the binary's own content is stale
	var stale := _stage(5)
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "staged == installed: discarded, content does not move")
	eq(_bi.active_pack_path, "", "staged == installed: nothing mounted")
	check(_bi.read_state().is_empty(), "staged == installed: state cleared")
	check(not FileAccess.file_exists(stale["path"]), "staged == installed: the stale pack is swept")
	_stage(3)
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "staged < installed: a newer binary is never rolled back")
	check(_bi.read_state().is_empty(), "staged < installed: state cleared")

	# a pack from another release stream is not ours, whatever its version
	_stage(7, "dev")
	_mount_from_clean(5, "")
	eq(_bi.content_version, 5, "pack from another branch: not mounted")
	check("different build stream" in _bi.pack_error, "pack from another branch: says why")
	check(_bi.read_state().is_empty(), "pack from another branch: state cleared")
	_stage(7, "")
	_mount_from_clean(5, "dev")
	eq(_bi.content_version, 5, "release pack on a branch build: not mounted either")
	_wipe()

	# a truncated pack is refused
	_stage(7, "", true, -1)
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "size mismatch: not mounted")
	check("truncated" in _bi.pack_error, "size mismatch: says why")
	check(_bi.read_state().is_empty(), "size mismatch: state cleared")

	# a pack that is not a pack fails to mount cleanly
	_wipe()
	DirAccess.make_dir_recursive_absolute(_bi.CONTENT_DIR)
	var junk: String = _bi.CONTENT_DIR.path_join("content-8.pck")
	var jf := FileAccess.open(junk, FileAccess.WRITE)
	jf.store_string("this is not a pack")
	jf.close()
	_bi.write_state({"content_version": 8, "pack_path": junk, "branch": "", "size": 18})
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "garbage pack: content version unchanged")
	check(_bi.active_pack_path == "", "garbage pack: nothing active")
	check(_bi.read_state().is_empty(), "garbage pack: state cleared")

	# the happy path last: a mounted pack stays mounted for the life of the process
	_wipe()
	var good := _stage(7)
	var other := _make_pack(6)
	check(FileAccess.file_exists(other["path"]), "(setup) a second pack exists to be swept")
	_mount_from_clean(5)
	eq(_bi.pack_error, "", "good pack: no error")
	eq(_bi.content_version, 7, "good pack: content version is the pack's")
	eq(_bi.base_content_version, 5, "good pack: the binary's own version is untouched")
	eq(_bi.active_pack_path, good["path"], "good pack: its path is recorded")
	check(FileAccess.file_exists(MARKER), "good pack: its files are visible under res://")
	var vj := FileAccess.open("res://version.json", FileAccess.READ)
	eq(vj.get_as_text() if vj != null else "", "pack 7", "good pack: its file replaces one the binary already ships")
	check(not FileAccess.file_exists(other["path"]), "good pack: other packs are swept")
	check(FileAccess.file_exists(good["path"]), "good pack: the mounted pack is kept")
	check(not _bi.read_state().is_empty(), "good pack: state stays so the next launch mounts it again")

	# no "size" key (state written before it existed) still mounts
	_wipe()
	_stage(11, "", true, 0, false)
	_mount_from_clean(5)
	eq(_bi.content_version, 11, "state without a size key: still mounts")


func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## Stages a real pack with a hand-built state: [param changes] are merged over the
## usual keys and every key in [param drop] is removed.
func _stage_state(version: int, changes := {}, drop := []) -> Dictionary:
	var pack := _make_pack(version)
	var state := {"content_version": version, "pack_path": pack["path"], "branch": "", "size": pack["size"]}
	state.merge(changes, true)
	for key: String in drop:
		state.erase(key)
	_bi.write_state(state)
	return pack


func _test_mount_edge_cases() -> void:
	# The order of the guards decides which reason a player-facing log gives, and
	# which of two bad states wins: branch, then rollback, then size.
	_wipe()
	_stage(3, "dev")
	_mount_from_clean(5, "")
	check("different build stream" in _bi.pack_error, "order: stale AND another stream is reported as the stream (branch first)")
	_wipe()
	_stage(3, "", true, -1)
	_mount_from_clean(5)
	eq(_bi.pack_error, "", "order: stale AND truncated is just stale (rollback before size)")
	_wipe()
	_stage(7, "dev", true, -1)
	_mount_from_clean(5, "")
	check("different build stream" in _bi.pack_error, "order: truncated AND another stream is reported as the stream (branch before size)")
	_wipe()
	_stage(7, "DEV")
	_mount_from_clean(5, "dev")
	eq(_bi.content_version, 5, "branch names are compared exactly, case included")

	# a discarded stale pack is not an error
	_wipe()
	_stage(5)
	_mount_from_clean(5)
	eq(_bi.pack_error, "", "stale pack: discarded quietly, no pack_error")

	# every way out of the mount clears the whole content dir, not just .pck files
	_wipe()
	_write_text(_bi.CONTENT_DIR.path_join("stray.txt"), "x")
	_stage(3)
	_mount_from_clean(5)
	check(not FileAccess.file_exists(_bi.CONTENT_DIR.path_join("stray.txt")), "stale: anything in the content dir is swept")
	_wipe()
	var other := _stage(7, "dev")
	_mount_from_clean(5, "")
	check(not FileAccess.file_exists(other["path"]), "another stream: the pack is swept")
	_wipe()
	var short := _stage(7, "", true, -1)
	_mount_from_clean(5)
	check(not FileAccess.file_exists(short["path"]), "truncated: the pack is swept")
	_wipe()
	var orphan := _make_pack(9)  # a pack with no state at all
	_mount_from_clean(5)
	check(not FileAccess.file_exists(orphan["path"]), "no state: an orphan pack is swept")
	_wipe()
	DirAccess.make_dir_recursive_absolute(_bi.CONTENT_DIR)
	var junk: String = _bi.CONTENT_DIR.path_join("content-8.pck")
	_write_text(junk, "this is not a pack")
	_bi.write_state({"content_version": 8, "pack_path": junk, "branch": "", "size": 18})
	_mount_from_clean(5)
	check("failed to mount" in _bi.pack_error, "garbage pack: pack_error says the mount failed")
	check(not FileAccess.file_exists(junk), "garbage pack: it is swept")

	# state as written by older builds, or damaged
	_wipe()
	_stage_state(7, {}, ["branch"])
	_mount_from_clean(5, "")
	eq(_bi.content_version, 7, "state with no branch key (older builds) is a release pack and mounts on a release build")
	_wipe()
	_stage_state(7, {}, ["branch"])
	_mount_from_clean(5, "dev")
	eq(_bi.content_version, 5, "...and is refused by a branch build")
	_wipe()
	_stage_state(7, {}, ["content_version"])
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "state with no content_version never mounts (it reads as 0, which is stale)")
	_wipe()
	_stage_state(7, {"size": 0})
	_mount_from_clean(5)
	check("truncated" in _bi.pack_error, "a recorded size of 0 is still a size: a non-empty pack does not match it")
	_wipe()
	_stage_state(7, {"pack_path": ""})
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "empty pack_path: nothing to mount")
	check(_bi.read_state().is_empty(), "empty pack_path: state cleared")

	_write_text(_bi.STATE_PATH, "[1, 2]")
	eq(_bi.read_state(), {}, "read_state: valid JSON that is not an object reads as empty")
	_write_text(_bi.STATE_PATH, "{not json")
	eq(_bi.read_state(), {}, "read_state: invalid JSON reads as empty")
	_bi.clear_state()


# ---------------------------------------------------------------------------
# BuildInfo: checksum at mount, staging sweep.  UpdateService: schema vs cache.
# ---------------------------------------------------------------------------

## Stages a real pack whose state records [param sha]; "" records the right one.
func _stage_sha(version: int, sha := "") -> Dictionary:
	var pack := _make_pack(version)
	_bi.write_state({"content_version": version, "pack_path": pack["path"], "branch": "",
			"size": pack["size"], "sha256": sha if sha != "" else FileAccess.get_sha256(pack["path"])})
	return pack


func _test_checksum_at_mount() -> void:
	_wipe()
	_stage_sha(21)
	_mount_from_clean(5)
	eq(_bi.content_version, 21, "checksum recorded and right: mounts")
	eq(_bi.pack_error, "", "checksum right: no error")

	# the manifest's hex may be any case and the state may carry stray whitespace
	_wipe()
	var upper := _make_pack(22)
	_bi.write_state({"content_version": 22, "pack_path": upper["path"], "branch": "", "size": upper["size"],
			"sha256": "  " + FileAccess.get_sha256(upper["path"]).to_upper() + " "})
	_mount_from_clean(5)
	eq(_bi.content_version, 22, "checksum in another case, padded: still compared as the same hash")

	# nothing recorded means nothing to compare: older state, or an empty value
	_wipe()
	_stage_sha(23)
	var state: Dictionary = _bi.read_state()
	state.erase("sha256")
	_bi.write_state(state)
	_mount_from_clean(5)
	eq(_bi.content_version, 23, "no sha256 key: still mounts")
	_wipe()
	var empty := _make_pack(24)
	_bi.write_state({"content_version": 24, "pack_path": empty["path"], "branch": "", "size": empty["size"], "sha256": ""})
	_mount_from_clean(5)
	eq(_bi.content_version, 24, "empty sha256: still mounts")

	# a recorded hash that is not the file's: refused, and the pack does not stay behind
	_wipe()
	var wrong := _stage_sha(25, "0".repeat(64))
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "wrong checksum: not mounted")
	check("checksum" in _bi.pack_error, "wrong checksum: says why")
	eq(_bi.active_pack_path, "", "wrong checksum: nothing active")
	check(_bi.read_state().is_empty(), "wrong checksum: state cleared")
	check(not FileAccess.file_exists(wrong["path"]), "wrong checksum: the pack is swept")

	# the case the size check cannot see: same length, different bytes
	_wipe()
	var tampered := _stage_sha(26)
	var f := FileAccess.open(tampered["path"], FileAccess.READ_WRITE)
	f.seek(f.get_length() - 1)
	var last := f.get_8()
	f.seek(f.get_length() - 1)
	f.store_8(last ^ 0xFF)
	f.close()
	eq(FileAccess.open(tampered["path"], FileAccess.READ).get_length(), tampered["size"], "(setup) the tampered pack keeps its size")
	_mount_from_clean(5)
	eq(_bi.content_version, 5, "same size, altered bytes: not mounted")
	check("checksum" in _bi.pack_error, "same size, altered bytes: caught by the checksum")

	# order: the cheap size check still comes first
	_wipe()
	var short := _make_pack(27)
	_bi.write_state({"content_version": 27, "pack_path": short["path"], "branch": "", "size": int(short["size"]) - 1,
			"sha256": "0".repeat(64)})
	_mount_from_clean(5)
	check("truncated" in _bi.pack_error, "order: truncated AND wrong checksum is reported as truncated")
	_wipe()


func _staging_file(file_name: String) -> String:
	DirAccess.make_dir_recursive_absolute(_bi.STAGING_DIR)
	var path: String = _bi.STAGING_DIR.path_join(file_name)
	_write_text(path, "x")
	return path


func _wipe_staging() -> void:
	var dir := DirAccess.open(_bi.STAGING_DIR)
	if dir != null:
		for file in dir.get_files():
			dir.remove(file)


func _newest_mtime(paths: Array) -> int:
	var newest := 0
	for path: String in paths:
		newest = maxi(newest, int(FileAccess.get_modified_time(path)))
	return newest


func _oldest_mtime(paths: Array) -> int:
	var oldest := 1 << 62
	for path: String in paths:
		oldest = mini(oldest, int(FileAccess.get_modified_time(path)))
	return oldest


func _test_staging_sweep() -> void:
	var real_binary: int = _bi.binary_version
	_bi.binary_version = 4
	_wipe_staging()

	# no staging dir at all is fine
	DirAccess.remove_absolute(_bi.STAGING_DIR)
	_bi._sweep_staging_dir()
	check(true, "no staging dir: nothing to sweep, no crash")

	var installed_apk := _staging_file("update-3.apk")
	var installed_exe := _staging_file("update-4.exe")
	var pending_apk := _staging_file("update-5.apk")
	var part := _staging_file("content-9.pck.part")
	var script := _staging_file("apply_update.ps1")
	var strangers := [_staging_file("notes.txt"), _staging_file("update-x.apk"), _staging_file("update-5.zip"),
			_staging_file("update-.apk"), _staging_file("update--3.apk"), _staging_file("update-3.apk.bak")]
	var content_pack := _make_pack(31)

	_bi._sweep_staging_dir()
	check(not FileAccess.file_exists(installed_apk), "an update at or below this binary's version is installed: swept")
	check(not FileAccess.file_exists(installed_exe), "an update AT this binary's version is swept too")
	check(FileAccess.file_exists(pending_apk), "an update for a newer binary is kept while it is fresh")
	check(FileAccess.file_exists(part), "a fresh .part is kept: another copy of the app may be writing it")
	check(FileAccess.file_exists(script), "a fresh apply_update.ps1 is kept: the helper may still be running")
	for path: String in strangers:
		check(FileAccess.file_exists(path), "a file the launcher did not write is left alone: " + path.get_file())
	check(FileAccess.file_exists(content_pack["path"]), "the content dir is not touched by the staging sweep")

	# age: strictly more than the limit since the last write. The files were written a moment
	# apart, so their whole-second times can differ: "kept" is judged from the oldest, "swept"
	# from the newest, which keeps the test from depending on a second not rolling over.
	eq(_bi.STAGING_MAX_AGE_SECONDS, 86400, "the staging age limit is 24 hours")
	var keepers := [pending_apk, part, script]
	var oldest := _oldest_mtime(keepers)
	var newest := _newest_mtime(keepers)
	_bi._sweep_staging_dir(oldest + _bi.STAGING_MAX_AGE_SECONDS)
	for path: String in keepers:
		check(FileAccess.file_exists(path), "exactly at the age limit: kept: " + path.get_file())
	_bi._sweep_staging_dir(newest + _bi.STAGING_MAX_AGE_SECONDS + 1)
	for path: String in keepers:
		check(not FileAccess.file_exists(path), "past the age limit: swept: " + path.get_file())
	for path: String in strangers:
		check(FileAccess.file_exists(path), "past the age limit, still left alone: " + path.get_file())

	# a clock that reads earlier than the file never deletes it
	var future := _staging_file("content-10.pck.part")
	_bi._sweep_staging_dir(int(FileAccess.get_modified_time(future)) - 10 * _bi.STAGING_MAX_AGE_SECONDS)
	check(FileAccess.file_exists(future), "a file dated after 'now' is kept")

	# a launch does it: a real BuildInfo, built from scratch, sweeps as it starts
	_wipe()
	_wipe_staging()
	var done := _staging_file("update-%d.apk" % real_binary)
	var next := _staging_file("update-%d.apk" % (real_binary + 1))
	var fresh: Node = load("res://addons/launcher/build_info.gd").new()
	check(not FileAccess.file_exists(done), "at launch: the update this binary already is gets swept")
	check(FileAccess.file_exists(next), "at launch: the one for a newer binary stays")
	fresh.free()

	_wipe_staging()
	_bi.binary_version = real_binary


func _test_too_new_manifest_is_not_cached() -> void:
	_reset_build(2)
	_us.manifest = {"schema": _us.SUPPORTED_SCHEMA + 1, "changelog": [_entry(9, ["new"])]}
	_us._interpret_manifest()
	eq(_us.state, _us.State.UNAVAILABLE, "a manifest from a newer schema: the check is refused")
	check(not FileAccess.file_exists(_us.CHANGELOG_CACHE_PATH), "a newer schema: its changelog is not cached")

	# and it cannot overwrite a good cache either
	_us.manifest = {"changelog": [_entry(6, ["a"])]}
	_us._cache_changelog()
	_us.manifest = {"schema": _us.SUPPORTED_SCHEMA + 1, "changelog": [_entry(9, ["new"])]}
	_us._interpret_manifest()
	eq(_versions(_us.full_changelog()), [6], "a newer schema: the menu in this same session still shows the cached history")
	_us.manifest = {}
	eq(_versions(_us.full_changelog()), [6], "a newer schema leaves the cached history as it was")

	# the ones this build can read are cached, including a manifest with no schema key at all
	for schema: Variant in [_us.SUPPORTED_SCHEMA, null]:
		_reset_build(2)
		_us.manifest = {"changelog": [_entry(8, ["b"])]}
		if schema != null:
			_us.manifest["schema"] = schema
		_us._interpret_manifest()
		_us.manifest = {}
		eq(_versions(_us.full_changelog()), [8], "a readable manifest (schema %s) is cached" % str(schema))
	_reset_build(2)


func _cleanup() -> void:
	_wipe_staging()
	_wipe()
	var dir := DirAccess.open("user://")
	if dir != null:
		for file in dir.get_files():
			if file.begins_with("marker-") or file.begins_with("override-") or file == "changelog.json":
				dir.remove(file)
