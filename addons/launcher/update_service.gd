extends Node
## Autoload: checks GitHub Releases for a newer build and applies it.
##
## Two kinds of update, decided by the manifest:
##
##   BINARY  -- binary_version went up. Only a new APK/EXE can deliver it.
##              On Android the APK is downloaded and handed to the system
##              installer, which updates this app in place.
##   CONTENT -- only content_version went up. A .pck is downloaded, staged in
##              user://, and mounted at the next launch, so the app just has to
##              restart. No reinstall, no app-store round trip.
##
## Every download is verified against the SHA-256 in the manifest before it is
## allowed anywhere near the install step.

const USER_AGENT := "GodotLauncher/1.0 (+https://github.com/sinikebe/godot-launcher-template)"
## Last fetched changelog, so patch notes stay readable with no network.
const CHANGELOG_CACHE_PATH := "user://changelog.json"
## HTTPRequest.timeout is total wall-clock from request(), not an idle timeout:
## it fires while bytes are still arriving. So the manifest and the artifacts
## cannot share one value -- a bound sized for a few hundred bytes of JSON
## cancels a download that is progressing perfectly well.
##
## The manifest is small and fetched on every launch, so it should give up fast.
const MANIFEST_TIMEOUT := 30.0

## Artifacts are tens to hundreds of megabytes -- the demo's own release is a
## 50 MB APK and a 104 MB EXE. At the old shared 30 s those needed 14.0 and
## 29.1 Mbps respectively just to finish, and anything slower failed outright
## with the partial file deleted and no resume. Half an hour brings that down to
## 0.23 and 0.49 Mbps.
##
## That is not "every connection": a 0.2 Mbps link -- congested cell, EDGE --
## still cannot finish either inside half an hour. It is the point past which
## the wait is the problem rather than the deadline, and where a cancel
## (issue #25) is the better answer than a larger number.
##
## Not 0 (unlimited): a peer that accepts and then goes silent would hang the
## download forever. `timeout` does not bound that case well anyway -- it waits
## on the peer rather than the clock in threaded mode. See issue #33.
const DOWNLOAD_TIMEOUT := 1800.0
const SUPPORTED_SCHEMA := 1

enum State {
	IDLE,             ## Nothing has been checked yet this session.
	CHECKING,         ## Manifest request in flight.
	UP_TO_DATE,       ## Manifest fetched, nothing newer.
	CONTENT_READY,    ## A content update is available to download.
	BINARY_READY,     ## A new APK/EXE is available to download.
	DOWNLOADING,      ## Transfer in flight.
	VERIFYING,        ## Hashing the finished download.
	RESTART_REQUIRED, ## Content staged; relaunch to finish.
	INSTALL_HANDOFF,  ## APK handed to the system installer.
	NEEDS_PERMISSION, ## APK downloaded and verified, but Android will not let us install it yet.
	UNAVAILABLE,      ## No build published for this platform.
	FAILED,           ## Check or download failed; see last_error.
}

signal state_changed(new_state: State)
signal progress_changed(downloaded_bytes: int, total_bytes: int)
## Emitted once per check or apply with the outcome, for one-shot UI reactions.
signal check_completed(final_state: State)

var state: State = State.IDLE
var last_error: String = ""
var manifest: Dictionary = {}

## Populated once a check finds something to download.
var pending_kind: String = ""      ## "binary" or "content"
var pending_artifact: Dictionary = {}
var pending_version: int = 0

var _busy := false
var _active_request: HTTPRequest = null
## Set once an APK has been downloaded and its checksum verified, so a retry
## after granting the install permission does not download it a second time.
var _verified_apk_path := ""


func _ready() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	# The manifest fetch goes through the same request helper, but a few hundred
	# bytes of JSON is not worth reporting as a download -- and doing so would
	# stomp the "Checking for updates…" status with a progress line.
	if _active_request == null or state != State.DOWNLOADING:
		return
	progress_changed.emit(_active_request.get_downloaded_bytes(), _active_request.get_body_size())


# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------

## Fetches the manifest and works out whether anything newer exists.
## Safe to call fire-and-forget; listen to [signal check_completed].
func check_for_updates() -> State:
	if _busy:
		return state
	if not BuildInfo.config.updates_enabled():
		return _finish(State.UNAVAILABLE,
			"No update repository configured (set update_repo in the launcher config).")

	# A game that copied the demo's config would poll the launcher template and
	# try to install the demo over itself. Refuse rather than do that.
	var source := BuildInfo.launcher_source()
	if not source.is_empty() and BuildInfo.config.update_repo == source:
		return _finish(State.UNAVAILABLE,
			"update_repo still points at the launcher template. Set it to this game's own repository.")
	_busy = true
	_set_state(State.CHECKING)
	last_error = ""

	# GitHub's CDN caches /releases/latest/download/ and ignores Cache-Control on
	# it, so a plain request can be answered with the previous release's manifest
	# for a while after a new one goes out. A unique query defeats that.
	var url := "%s?ts=%d" % [BuildInfo.config.manifest_url(), Time.get_unix_time_from_system()]
	var response := await _request(url, "")
	_busy = false

	if not response.ok:
		if response.code == 404:
			return _fail("No release has been published yet.")
		return _fail(response.error)

	var parsed: Variant = JSON.parse_string(response.body.get_string_from_utf8())
	if not parsed is Dictionary:
		return _fail("The update manifest is malformed.")

	manifest = parsed
	_cache_changelog()
	var schema := int(manifest.get("schema", 0))
	if schema > SUPPORTED_SCHEMA:
		return _finish(State.UNAVAILABLE,
			"This build is too old to understand the update feed. Please reinstall from GitHub.")

	var platform := BuildInfo.platform_key()
	var artifacts: Dictionary = manifest.get("artifacts", {})
	var remote_binary := int(manifest.get("binary_version", 0))
	var remote_content := int(manifest.get("content_version", 0))

	# A new binary wins: it carries its own content, so there is no point
	# downloading a content pack that the install would immediately supersede.
	if remote_binary > BuildInfo.binary_version:
		var binary_artifact := _artifact_for(artifacts, "binary", platform)
		if binary_artifact.is_empty():
			return _finish(State.UNAVAILABLE,
				"Version %s needs a new app build, but none is published for %s yet." % [
					manifest.get("version_name", "?"), platform])
		pending_kind = "binary"
		pending_artifact = binary_artifact
		pending_version = remote_binary
		return _finish(State.BINARY_READY, "")

	if remote_content > BuildInfo.content_version:
		var content_artifact := _artifact_for(artifacts, "content", platform)
		if content_artifact.is_empty():
			return _finish(State.UNAVAILABLE, "No content pack published for %s." % platform)
		pending_kind = "content"
		pending_artifact = content_artifact
		pending_version = remote_content
		return _finish(State.CONTENT_READY, "")

	pending_kind = ""
	pending_artifact = {}
	pending_version = 0
	return _finish(State.UP_TO_DATE, "")


func _artifact_for(artifacts: Dictionary, kind: String, platform: String) -> Dictionary:
	var by_platform: Variant = artifacts.get(kind, {})
	if not by_platform is Dictionary:
		return {}
	var entry: Variant = by_platform.get(platform, {})
	if not entry is Dictionary or not entry.has("url"):
		return {}
	return entry


# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

## Downloads and applies whatever the last check turned up.
func apply_pending_update() -> State:
	if _busy or pending_artifact.is_empty():
		return state
	if pending_kind == "binary":
		return await _apply_binary()
	return await _apply_content()


func _apply_content() -> State:
	_busy = true
	var url := str(pending_artifact.get("url", ""))
	var version := pending_version

	DirAccess.make_dir_recursive_absolute(BuildInfo.STAGING_DIR)
	DirAccess.make_dir_recursive_absolute(BuildInfo.CONTENT_DIR)

	var staged := BuildInfo.STAGING_DIR.path_join("content-%d.pck.part" % version)
	var download_state := await _download_verified(url, staged)
	if download_state != State.VERIFYING:
		_busy = false
		return download_state

	# Per-version filename: the pack mounted by this process stays locked on
	# Windows, so a new one must never try to overwrite it.
	var final_path := BuildInfo.CONTENT_DIR.path_join("content-%d.pck" % version)
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(final_path)
	if DirAccess.rename_absolute(staged, final_path) != OK:
		_busy = false
		return _fail("Could not move the downloaded content into place.")

	var size := 0
	var probe := FileAccess.open(final_path, FileAccess.READ)
	if probe != null:
		size = probe.get_length()

	BuildInfo.write_state({
		"content_version": version,
		"pack_path": final_path,
		"size": size,
		"sha256": str(pending_artifact.get("sha256", "")),
		"version_name": str(manifest.get("version_name", "")),
		"installed_at": Time.get_datetime_string_from_system(true),
	})

	_busy = false
	return _finish(State.RESTART_REQUIRED, "")


func _apply_binary() -> State:
	_busy = true
	var url := str(pending_artifact.get("url", ""))

	if BuildInfo.is_android():
		DirAccess.make_dir_recursive_absolute(BuildInfo.STAGING_DIR)
		var apk_path := BuildInfo.STAGING_DIR.path_join("update-%d.apk" % pending_version)

		# Backing out of the system installer leaves a good APK on disk. Re-hash
		# it rather than pulling ~50 MB down again -- cheap, and it keeps the
		# "never install anything unverified" rule intact.
		if _matches_pending_checksum(apk_path):
			_verified_apk_path = apk_path
			_busy = false
			return _hand_off_to_installer()

		var download_state := await _download_verified(url, apk_path)
		if download_state != State.VERIFYING:
			_busy = false
			return download_state

		_verified_apk_path = apk_path
		_busy = false
		return _hand_off_to_installer()

	if OS.get_name() == "Windows":
		var result := await _apply_windows_binary(url)
		_busy = false
		return result

	# Nothing safe to automate here: point at the release page.
	_busy = false
	OS.shell_open(BuildInfo.config.releases_url())
	return _finish(State.UNAVAILABLE, "Download the new build from the GitHub releases page.")


## Hands the already-downloaded, already-verified APK to the system installer.
##
## Split out from the download so that granting the install permission and
## trying again does not mean fetching ~50 MB a second time.
func _hand_off_to_installer() -> State:
	if _verified_apk_path.is_empty() or not FileAccess.file_exists(_verified_apk_path):
		# Staging was cleared from under us; fall back to downloading again.
		_verified_apk_path = ""
		return _finish(State.BINARY_READY, "")

	if not AndroidBridge.can_install_packages():
		AndroidBridge.open_install_settings()
		return _finish(State.NEEDS_PERMISSION,
			"Allow %s to install unknown apps, then tap Install." % BuildInfo.config.game_title)

	if not AndroidBridge.install_apk(_verified_apk_path):
		# The APK sits in private storage, so there is nothing the user could
		# open by hand. Send them to the release page instead -- a browser
		# download lands somewhere they can install from.
		OS.shell_open(BuildInfo.config.releases_url())
		return _fail("Could not open the installer. Opened the releases page so you can download the APK directly.")

	return _finish(State.INSTALL_HANDOFF, "")


## Retries the install after the user has granted the permission.
func retry_install() -> State:
	if _busy:
		return state
	if _verified_apk_path.is_empty():
		return await apply_pending_update()
	return _hand_off_to_installer()


# ---------------------------------------------------------------------------
# Transfer helpers
# ---------------------------------------------------------------------------

## Downloads [param url] to [param dest] and checks it against the manifest
## hash. Returns State.VERIFYING on success, or a failure state.
func _download_verified(url: String, dest: String) -> State:
	if url.is_empty():
		return _fail("The manifest entry has no download URL.")

	_set_state(State.DOWNLOADING)
	var response := await _request(url, dest)
	if not response.ok:
		DirAccess.remove_absolute(dest)
		return _fail(response.error)

	_set_state(State.VERIFYING)
	var expected := str(pending_artifact.get("sha256", "")).strip_edges().to_lower()
	if expected.is_empty():
		# Refuse to install something we cannot authenticate.
		DirAccess.remove_absolute(dest)
		return _fail("The manifest is missing a checksum for this download.")

	var actual := FileAccess.get_sha256(dest).to_lower()
	if actual != expected:
		DirAccess.remove_absolute(dest)
		return _fail("The download is corrupted (checksum mismatch) and was discarded.")

	return State.VERIFYING


## True when [param path] already holds exactly the bytes the manifest expects.
func _matches_pending_checksum(path: String) -> bool:
	var expected := str(pending_artifact.get("sha256", "")).strip_edges().to_lower()
	if expected.is_empty() or not FileAccess.file_exists(path):
		return false
	return FileAccess.get_sha256(path).to_lower() == expected


## One HTTP GET. When [param download_to] is set the body is streamed to that
## file instead of being kept in memory.
func _request(url: String, download_to: String) -> Dictionary:
	var http := HTTPRequest.new()
	# download_to is set only for artifacts, so it is also the signal for which
	# budget applies -- the one call site that streams to a file is the one that
	# needs the long one.
	http.timeout = DOWNLOAD_TIMEOUT if not download_to.is_empty() else MANIFEST_TIMEOUT
	http.use_threads = true
	# GitHub serves release assets from a redirect to a signed CDN URL.
	http.max_redirects = 8
	if not download_to.is_empty():
		http.download_file = download_to
	add_child(http)

	_active_request = http
	set_process(true)

	var headers := PackedStringArray([
		"User-Agent: " + USER_AGENT,
		"Accept: */*",
		"Cache-Control: no-cache",
	])

	var error := http.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		_teardown_request(http)
		return {
			"ok": false, "code": 0, "body": PackedByteArray(),
			"error": "Could not start the request (error %d). Check your connection." % error,
		}

	var result: Array = await http.request_completed
	_teardown_request(http)

	var outcome := int(result[0])
	var code := int(result[1])
	var body: PackedByteArray = result[3]

	if outcome != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": code, "body": body, "error": _describe_transfer_failure(outcome)}
	if code < 200 or code >= 300:
		return {"ok": false, "code": code, "body": body, "error": "The server answered with HTTP %d." % code}

	return {"ok": true, "code": code, "body": body, "error": ""}


func _teardown_request(http: HTTPRequest) -> void:
	_active_request = null
	set_process(false)
	http.queue_free()


func _describe_transfer_failure(outcome: int) -> String:
	match outcome:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "Could not reach GitHub. Check your connection."
		HTTPRequest.RESULT_TIMEOUT:
			return "The connection timed out."
		# A peer that stalls and then drops surfaces here rather than as
		# RESULT_TIMEOUT once the deadline is long enough not to fire first --
		# same cause as far as the player is concerned, so say the same thing
		# instead of falling through to a bare error number.
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "The connection dropped part-way through. Try again."
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "Secure connection failed."
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN, HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR:
			return "Could not write the download to storage. Is the device full?"
		_:
			return "The download failed (error %d)." % outcome


# ---------------------------------------------------------------------------
# Restarting
# ---------------------------------------------------------------------------

## Relaunches the app so a staged content pack gets mounted.
## Returns false if the caller has to ask the user to do it by hand.
func restart_app() -> bool:
	if BuildInfo.is_android():
		return AndroidBridge.restart_app()

	if OS.has_feature("editor"):
		# get_executable_path() is the editor binary here, so relaunching it
		# would open the editor rather than the game.
		return false

	var executable := OS.get_executable_path()
	if executable.is_empty():
		return false
	if OS.create_process(executable, []) <= 0:
		return false
	get_tree().quit()
	return true


# ---------------------------------------------------------------------------
# Windows in-place update
# ---------------------------------------------------------------------------

## Downloads the new .exe and leaves a detached helper that swaps it in once
## this process has exited -- a running .exe cannot overwrite itself.
##
## The Windows build is a single self-contained executable (the content pack is
## embedded at export time), so "installing" it is one file copy.
func _apply_windows_binary(url: String) -> State:
	DirAccess.make_dir_recursive_absolute(BuildInfo.STAGING_DIR)
	var staged := BuildInfo.STAGING_DIR.path_join("update-%d.exe" % pending_version)

	var download_state := await _download_verified(url, staged)
	if download_state != State.VERIFYING:
		return download_state

	if OS.has_feature("editor"):
		return _finish(State.UNAVAILABLE,
			"Running from the editor — the new build was saved to %s." %
				ProjectSettings.globalize_path(staged))

	if not _spawn_windows_swap(staged, OS.get_executable_path()):
		return _fail("Could not start the updater. The new build is at %s." %
			ProjectSettings.globalize_path(staged))

	get_tree().quit()
	return _finish(State.INSTALL_HANDOFF, "")


func _spawn_windows_swap(source_exe: String, target_exe: String) -> bool:
	var script_res_path := BuildInfo.STAGING_DIR.path_join("apply_update.ps1")
	var script := FileAccess.open(script_res_path, FileAccess.WRITE)
	if script == null:
		return false
	# $PID is a reserved automatic variable in PowerShell, hence $OwnerPid.
	var lines := PackedStringArray([
		"param([int]$OwnerPid, [string]$Source, [string]$Target)",
		"$ErrorActionPreference = 'Stop'",
		"try { Wait-Process -Id $OwnerPid -Timeout 60 -ErrorAction SilentlyContinue } catch {}",
		"Start-Sleep -Milliseconds 750",
		"Copy-Item -LiteralPath $Source -Destination $Target -Force",
		"Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue",
		"Start-Process -FilePath $Target -WorkingDirectory (Split-Path -Parent $Target)",
	])
	script.store_string("\r\n".join(lines) + "\r\n")
	script.close()

	return OS.create_process("powershell.exe", [
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", ProjectSettings.globalize_path(script_res_path),
		"-OwnerPid", str(OS.get_process_id()),
		"-Source", ProjectSettings.globalize_path(source_exe),
		"-Target", target_exe,
	]) > 0


# ---------------------------------------------------------------------------
# State plumbing
# ---------------------------------------------------------------------------

func _set_state(next: State) -> void:
	state = next
	state_changed.emit(state)


func _fail(message: String) -> State:
	last_error = message
	push_warning("[UpdateService] " + message)
	_set_state(State.FAILED)
	check_completed.emit(state)
	return state


func _finish(next: State, message: String) -> State:
	last_error = message
	_set_state(next)
	check_completed.emit(state)
	return state


## Every release this app knows about, newest first.
##
## Prefers the manifest from the current session, falls back to the copy cached
## at the last successful check, and always includes the running build's own
## notes -- so the history is readable offline and on a fresh install that has
## never reached the network.
func full_changelog() -> Array:
	var source: Variant = manifest.get("changelog", [])
	if not (source is Array and not source.is_empty()):
		source = _read_cached_changelog()

	var entries: Array = []
	var seen := {}
	if source is Array:
		for entry: Variant in source:
			if entry is Dictionary:
				var version := int(entry.get("content_version", -1))
				if not seen.has(version):
					seen[version] = true
					entries.append(entry)

	if not seen.has(BuildInfo.content_version) and not BuildInfo.own_changes.is_empty():
		entries.append({
			"content_version": BuildInfo.content_version,
			"version_name": BuildInfo.version_name,
			"released_at": BuildInfo.built_at,
			"changes": BuildInfo.own_changes,
		})

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("content_version", 0)) > int(b.get("content_version", 0)))
	return entries


## The patch notes covering everything between the installed build and the
## release on offer, newest first.
##
## Entries at or below the installed content version are already in this build,
## so they are dropped -- the player only sees what they are about to get.
func pending_changelog() -> Array:
	var entries: Variant = manifest.get("changelog", [])
	if not entries is Array:
		return []

	var result: Array = []
	for entry: Variant in entries:
		if entry is Dictionary and int(entry.get("content_version", 0)) > BuildInfo.content_version:
			result.append(entry)
	return result


## The pending patch notes as display text, capped so the dialog cannot outgrow
## the screen. Empty when there is nothing to show.
func pending_notes_text(max_lines: int = 12) -> String:
	return _format_entries(pending_changelog(), max_lines, false)


## The whole known history, with the running build marked. Shown on demand, so
## it is allowed to be long -- the dialog scrolls.
func history_text(max_lines: int = 400) -> String:
	return _format_entries(full_changelog(), max_lines, true)


## Whether history_text() would return anything -- the question to ask before
## offering to show it.
##
## Not the same question as full_changelog().is_empty(). That counts entries;
## _format_entries skips any whose "changes" is missing or an empty array, so a
## history of nothing but chore-only releases is non-empty by one test and
## renders as "" by the other. ci/collect_changes.sh drops chore/ci/bump/wip/
## revert subjects and ci/make_manifest.py emits the release entry regardless,
## so "changes": [] is something the pipeline really ships.
##
## Cheaper than formatting the history to find out: one full_changelog() plus a
## scan that stops at the first entry with content, rather than building every
## line of every entry and measuring the result.
func has_notes() -> bool:
	for entry: Dictionary in full_changelog():
		# The same test _format_entries makes, inverted.
		var changes: Variant = entry.get("changes", [])
		if changes is Array and not changes.is_empty():
			return true
	return false


func _format_entries(entries: Array, max_lines: int, mark_installed: bool) -> String:
	var lines: PackedStringArray = []
	var dropped := 0

	for entry: Dictionary in entries:
		var changes: Variant = entry.get("changes", [])
		if not changes is Array or changes.is_empty():
			continue

		var version := int(entry.get("content_version", 0))
		var heading := "v%s  ·  build %d" % [entry.get("version_name", "?"), version]
		if mark_installed and version == BuildInfo.content_version:
			heading += "     ← installed"

		if lines.size() >= max_lines:
			dropped += changes.size()
			continue

		if not lines.is_empty():
			lines.append("")
		lines.append(heading)

		for change: Variant in changes:
			if lines.size() >= max_lines:
				dropped += 1
			else:
				lines.append("  •  %s" % str(change))

	if lines.is_empty():
		return ""
	if dropped > 0:
		lines.append("")
		lines.append("…and %d more change%s." % [dropped, "" if dropped == 1 else "s"])
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# Changelog cache
# ---------------------------------------------------------------------------

## Keeps the last fetched changelog on disk so the history stays readable with
## no network -- on a plane, or simply before the first check of a session.
func _cache_changelog() -> void:
	var entries: Variant = manifest.get("changelog", [])
	if not entries is Array or entries.is_empty():
		return
	var file := FileAccess.open(CHANGELOG_CACHE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"cached_at": Time.get_datetime_string_from_system(true),
		"changelog": entries,
	}, "\t"))


func _read_cached_changelog() -> Array:
	if not FileAccess.file_exists(CHANGELOG_CACHE_PATH):
		return []
	var file := FileAccess.open(CHANGELOG_CACHE_PATH, FileAccess.READ)
	if file == null:
		return []
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and parsed.get("changelog") is Array:
		return parsed["changelog"]
	return []


## One line describing where the updater currently stands, for the menu.
func status_text() -> String:
	match state:
		State.IDLE:
			return "Not checked yet."
		State.CHECKING:
			return "Checking for updates…"
		State.UP_TO_DATE:
			return "Up to date."
		State.DOWNLOADING:
			return "Downloading…"
		State.VERIFYING:
			return "Verifying download…"
		State.CONTENT_READY:
			return "Content update available (v%s)." % manifest.get("version_name", pending_version)
		State.BINARY_READY:
			return "New app version available (v%s)." % manifest.get("version_name", pending_version)
		State.RESTART_REQUIRED:
			return "Update ready — restart to finish."
		State.INSTALL_HANDOFF:
			return "Handed over to the installer."
		State.NEEDS_PERMISSION, State.UNAVAILABLE, State.FAILED:
			return last_error
		_:
			return ""
