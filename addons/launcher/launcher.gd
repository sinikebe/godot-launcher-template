extends Control
## The launcher screen. Everything it shows comes from [LauncherConfig]; nothing
## in this file should need editing to reskin a game's launcher.
##
## Update logic lives in UpdateService; this file only drives the UI.

## Emitted when one of [member LauncherConfig.extra_buttons] is pressed, with
## that button's label. Connect it from [constant HOOKS_PATH]'s
## _launcher_opening() to add Settings, Credits or anything else without
## modifying the launcher.
signal custom_button_pressed(label: String)

## Emitted when Play is pressed, before it changes scene. With no play scene
## configured, connecting this takes the Play action over entirely.
signal play_requested()

## The game's own script for the launcher's screen, run before it builds
## anything when the file exists. See _run_opening_hook().
const HOOKS_PATH := "res://launcher_hooks.gd"

## Height the patch-note history is capped at before it starts scrolling.
const HISTORY_VIEW_HEIGHT := 300.0

## What [method register_translations] accepts inside a folder: gettext catalogs,
## and the .translation files Godot imports from a CSV.
const CATALOG_EXTENSIONS: PackedStringArray = ["po", "mo", "translation"]

## Catalogs [method register_translations] has already read in this process. A
## content pack cannot change until the next launch, so reading one again each
## time the launcher reopens would only repeat work.
static var _registered_catalogs: Dictionary = {}

@onready var _bg_color: ColorRect = %BackgroundColor
@onready var _bg_texture: TextureRect = %BackgroundTexture
@onready var _bg_shader: ColorRect = %BackgroundShader
@onready var _bg_dim: ColorRect = %BackgroundDim

@onready var _title_block: VBoxContainer = %TitleBlock
@onready var _title: Label = %Title
@onready var _tagline: Label = %Tagline

@onready var _menu_block: VBoxContainer = %MenuBlock
@onready var _version_label: Label = %VersionLabel

@onready var _bottom_stack: VBoxContainer = %BottomStack
@onready var _update_bar: PanelContainer = %UpdateBar
@onready var _status_label: Label = %StatusLabel
@onready var _update_button: Button = %UpdateButton
@onready var _notes_button: Button = %NotesButton
@onready var _progress: ProgressBar = %UpdateProgress

@onready var _overlay: Control = %UpdateOverlay
@onready var _overlay_title: Label = %OverlayTitle
@onready var _overlay_scroll: ScrollContainer = %OverlayScroll
@onready var _overlay_body: Label = %OverlayBody
@onready var _overlay_primary: Button = %OverlayPrimary
@onready var _overlay_secondary: Button = %OverlaySecondary

var _config: LauncherConfig
var _menu_box: BoxContainer
var _first_button: Button = null
## Guards the re-entrancy between _apply_layout() and minimum_size_changed.
var _laying_out := false
## What the overlay's primary button should do when pressed.
var _overlay_action: Callable = Callable()
## Shows the open overlay again from scratch, so a language change can re-say it.
var _overlay_resay: Callable = Callable()
## True while a language change re-says the overlay, which must leave the
## player's focus and scroll position where they were.
var _resaying := false
## Set once _ready() has built the screen. Before then there is nothing to
## retranslate -- and a language change can arrive earlier than that, from the
## game's own hook calling TranslationServer.set_locale().
var _screen_built := false
## The game's hooks object, held for as long as the launcher is up so that
## signals it connected to its own methods keep working.
var _hooks: Object = null


func _ready() -> void:
	_config = BuildInfo.config
	# First, so whatever the game sets up -- its catalogs, a language the player
	# chose -- is already in force when the screen below is built.
	_run_opening_hook()

	if _config.theme_override != null:
		theme = _config.theme_override

	_apply_identity()
	_apply_background()
	_build_menu()
	_apply_layout()

	_overlay.hide()
	_progress.hide()
	_version_label.text = BuildInfo.display_version()

	_notes_button.pressed.connect(_show_history)
	_update_button.pressed.connect(_on_update_pressed)
	_overlay_primary.pressed.connect(_on_overlay_primary)
	_overlay_secondary.pressed.connect(_hide_overlay)

	UpdateService.state_changed.connect(_on_update_state_changed)
	UpdateService.progress_changed.connect(_on_progress_changed)

	if not BuildInfo.pack_error.is_empty():
		push_warning("[Launcher] " + BuildInfo.pack_error)

	# Only the bar is conditional; the version stamp shares the stack and should
	# survive a project that has the updater turned off.
	_update_bar.visible = _config.show_update_bar and _config.updates_enabled()
	_refresh_update_ui()
	_screen_built = true

	if _first_button != null:
		_first_button.grab_focus()
	_apply_layout.call_deferred()

	if _config.check_on_launch and _config.updates_enabled():
		# Let the launcher paint before touching the network.
		await get_tree().create_timer(0.4).timeout
		await UpdateService.check_for_updates()


## Follows a language change made while the launcher is showing. The menu and
## the title translate themselves; the nodes refilled here are filled with tr()
## instead -- so a placeholder can be filled after translating -- and nothing
## else would ever refill them.
func _notification(what: int) -> void:
	if what != NOTIFICATION_TRANSLATION_CHANGED or not _screen_built:
		return
	_apply_identity()
	_refresh_update_ui()
	if _overlay.visible and _overlay_resay.is_valid():
		_resaying = true
		_overlay_resay.call()
		_resaying = false


# ---------------------------------------------------------------------------
# The game's own code, and its languages
# ---------------------------------------------------------------------------

## Runs _launcher_opening(launcher) from [constant HOOKS_PATH], if the game has
## that file, before anything is built.
##
## Its own file rather than a method on the config. A script that fails to parse
## cannot be loaded, and as the config's script that would cost the whole config:
## BuildInfo falls back to defaults with no update_repo, the updater turns off,
## and players who installed the broken content could never receive its fix.
## Here a broken file costs only the hooks, and the next content update can
## repair it.
##
## The file ships in content packs like any other game script, and it is this
## launcher -- the pack's -- that runs it, so it works the same on every binary.
func _run_opening_hook() -> void:
	if not ResourceLoader.exists(HOOKS_PATH):
		return
	var script := load(HOOKS_PATH) as Script
	if script == null or not script.can_instantiate():
		push_warning("[Launcher] %s could not be loaded; carrying on without it." % HOOKS_PATH)
		return
	_hooks = script.new()
	if _hooks == null:
		push_warning("[Launcher] %s could not be instantiated; carrying on without it." % HOOKS_PATH)
		return
	if _hooks is Node:
		# Freed with the launcher, instead of leaking once the scene changes.
		add_child(_hooks)
	if _hooks.has_method("_launcher_opening"):
		_hooks.call("_launcher_opening", self)


## Registers a game's translation catalogs -- .po, .mo or imported .translation
## files, or folders holding them directly -- as res:// has them now, a mounted
## content pack included. Call it from _launcher_opening() in [constant HOOKS_PATH].
##
## Project Settings → Localization cannot do this. The engine reads that list
## from the installed binary before any pack is mounted, so a corrected string
## or a new language shipped as a content update never takes effect there. A
## catalog already registered that way at the same path is replaced by the copy
## read here; one left at another path is not, and Godot then picks between the
## two by registration order.
func register_translations(paths: PackedStringArray) -> void:
	for path in _catalog_files(paths):
		if _registered_catalogs.has(path):
			continue
		# CACHE_MODE_IGNORE because a catalog the engine registered at startup is
		# cached under this same path, and a plain load() hands back that copy --
		# the binary's -- instead of reading the pack's.
		var catalog := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Translation
		if catalog == null:
			push_warning("[Launcher] %s is not a translation catalog; skipped." % path)
			continue
		for registered in TranslationServer.get_translations():
			if registered.resource_path == path:
				TranslationServer.remove_translation(registered)
		TranslationServer.add_translation(catalog)
		_registered_catalogs[path] = true


## [param paths] with each folder replaced by the catalogs directly inside it.
static func _catalog_files(paths: PackedStringArray) -> PackedStringArray:
	var files := PackedStringArray()
	for path in paths:
		if not DirAccess.dir_exists_absolute(path):
			files.append(path)
			continue
		# ResourceLoader rather than DirAccess, which in an exported game lists
		# the .remap and .import stand-ins instead of the files behind them.
		var entries := ResourceLoader.list_directory(path)
		entries.sort()
		var found := 0
		for entry in entries:
			if entry.get_extension().to_lower() in CATALOG_EXTENSIONS:
				files.append(path.path_join(entry))
				found += 1
		if found == 0:
			push_warning("[Launcher] %s holds no translation catalogs (subfolders are not searched)." % path)
	return files


# ---------------------------------------------------------------------------
# Appearance
# ---------------------------------------------------------------------------

func _apply_identity() -> void:
	_title.text = _config.game_title
	var tagline := _resolved_tagline()
	_tagline.text = tagline
	_tagline.visible = not tagline.is_empty()


## The tagline translated as written, then its placeholders filled -- the same
## result as LauncherConfig.resolved_tagline() on a current binary. Done here
## because that method runs at the installed binary's version, and one built
## before launcher 2.3.0 fills the placeholders without translating at all.
func _resolved_tagline() -> String:
	if _config.tagline.is_empty():
		return ""
	return tr(_config.tagline) \
		.replace("{build}", str(BuildInfo.content_version)) \
		.replace("{version}", BuildInfo.version_name)


func _apply_background() -> void:
	_bg_color.color = _config.background_color

	# A texture wins over the shader: an explicit image is always the more
	# deliberate choice than the bundled default.
	if _config.background_texture != null:
		_bg_texture.texture = _config.background_texture
		_bg_texture.stretch_mode = _stretch_mode_for(_config.background_stretch)
		_bg_texture.show()
		_bg_shader.hide()
	elif _config.background_shader != null:
		var material := ShaderMaterial.new()
		material.shader = _config.background_shader
		_bg_shader.material = material
		_bg_shader.show()
		_bg_texture.hide()
	else:
		_bg_texture.hide()
		_bg_shader.hide()

	_bg_dim.color = Color(0, 0, 0, _config.background_dim)
	_bg_dim.visible = _config.background_dim > 0.0


func _stretch_mode_for(index: int) -> int:
	match index:
		0: return TextureRect.STRETCH_SCALE
		1: return TextureRect.STRETCH_TILE
		2: return TextureRect.STRETCH_KEEP_CENTERED
		4: return TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_: return TextureRect.STRETCH_KEEP_ASPECT_COVERED


# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

func _build_menu() -> void:
	_menu_box = VBoxContainer.new() if _config.menu_orientation == 0 else HBoxContainer.new()
	_menu_box.add_theme_constant_override("separation", _config.menu_separation)
	if _config.menu_orientation == 0:
		_menu_box.custom_minimum_size.x = _config.menu_width
	# MenuBlock is a container so it reports the button box's minimum size and
	# lays it out; anchoring it with PRESET_MODE_MINSIZE then has a real size to
	# work from, which a bare Control would not have provided.
	_menu_block.add_child(_menu_box)
	_menu_block.minimum_size_changed.connect(_apply_layout)

	if _config.show_play:
		_add_button(_config.play_text, _on_play_pressed)
	for label in _config.extra_buttons:
		var text := str(label)
		if text.is_empty():
			continue
		_add_button(text, func() -> void: custom_button_pressed.emit(text))
	if _config.show_quit:
		_add_button(_config.quit_text, _on_quit_pressed)


func _add_button(text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	_menu_box.add_child(button)
	if _first_button == null:
		_first_button = button


## Positions the title and menu blocks from the config's alignment settings.
##
## Anchors rather than containers, so the two blocks can be placed independently
## anywhere on screen and still follow a resize.
func _apply_layout() -> void:
	if _laying_out:
		return
	_laying_out = true

	var margin := float(_config.edge_margin)
	_title_block.set_anchors_and_offsets_preset(
		_preset_for(_config.title_h_align, _config.title_v_align),
		Control.PRESET_MODE_MINSIZE, int(margin))
	_menu_block.set_anchors_and_offsets_preset(
		_preset_for(_config.menu_h_align, _config.menu_v_align),
		Control.PRESET_MODE_MINSIZE, int(margin))

	_title.horizontal_alignment = _text_align_for(_config.title_h_align)
	_tagline.horizontal_alignment = _text_align_for(_config.title_h_align)

	_bottom_stack.offset_left = margin
	_bottom_stack.offset_right = -margin
	_bottom_stack.offset_bottom = -margin

	_laying_out = false


func _preset_for(h_align: int, v_align: int) -> Control.LayoutPreset:
	match [h_align, v_align]:
		[0, 0]: return Control.PRESET_TOP_LEFT
		[1, 0]: return Control.PRESET_CENTER_TOP
		[2, 0]: return Control.PRESET_TOP_RIGHT
		[0, 1]: return Control.PRESET_CENTER_LEFT
		[2, 1]: return Control.PRESET_CENTER_RIGHT
		[0, 2]: return Control.PRESET_BOTTOM_LEFT
		[1, 2]: return Control.PRESET_CENTER_BOTTOM
		[2, 2]: return Control.PRESET_BOTTOM_RIGHT
		_: return Control.PRESET_CENTER


func _text_align_for(h_align: int) -> HorizontalAlignment:
	match h_align:
		1: return HORIZONTAL_ALIGNMENT_CENTER
		2: return HORIZONTAL_ALIGNMENT_RIGHT
		_: return HORIZONTAL_ALIGNMENT_LEFT


# ---------------------------------------------------------------------------
# Menu actions
# ---------------------------------------------------------------------------

func _on_play_pressed() -> void:
	play_requested.emit()
	if _config.play_scene.is_empty():
		# A game listening to play_requested has taken Play over; only Play that
		# nothing answers explains itself.
		if play_requested.get_connections().is_empty():
			_explain_play()
		return
	get_tree().change_scene_to_file(_config.play_scene)


func _explain_play() -> void:
	_show_overlay(
		tr("Not wired up yet"),
		tr("This is where the game starts. Set play_scene in the launcher config, or connect the launcher's play_requested signal to take over."),
		tr("OK"), Callable(self, "_hide_overlay"), "", _explain_play)


func _on_quit_pressed() -> void:
	get_tree().quit()


## The update button is the single entry point: it checks, then downloads, then
## restarts, depending on where the updater currently is.
func _on_update_pressed() -> void:
	match UpdateService.state:
		UpdateService.State.CONTENT_READY, UpdateService.State.BINARY_READY:
			await _prompt_update()
		UpdateService.State.NEEDS_PERMISSION:
			await UpdateService.retry_install()
		UpdateService.State.RESTART_REQUIRED:
			_prompt_restart()
		_:
			await UpdateService.check_for_updates()


# ---------------------------------------------------------------------------
# Update UI
# ---------------------------------------------------------------------------

func _on_update_state_changed(_new_state: int) -> void:
	_refresh_update_ui()

	match UpdateService.state:
		UpdateService.State.RESTART_REQUIRED:
			_prompt_restart()
		UpdateService.State.INSTALL_HANDOFF:
			_explain_install_handoff()
		_:
			pass


func _explain_install_handoff() -> void:
	_show_overlay(
		tr("Installing"),
		tr("Confirm the update in the system installer. The game will reopen on the new version once the install finishes."),
		tr("OK"), Callable(self, "_hide_overlay"), "", _explain_install_handoff)


func _refresh_update_ui() -> void:
	_status_label.text = UpdateService.status_text()

	var busy := UpdateService.state in [
		UpdateService.State.CHECKING,
		UpdateService.State.DOWNLOADING,
		UpdateService.State.VERIFYING,
	]
	_progress.visible = UpdateService.state == UpdateService.State.DOWNLOADING
	_update_button.disabled = busy

	# A fresh install that has never reached the network has no notes to show,
	# and a button that only opens "nothing recorded yet" is worse than no button.
	#
	# has_notes(), not full_changelog().is_empty(): the latter counts entries the
	# dialog then skips for having no changes, which is exactly what a release of
	# nothing but chore commits produces.
	_notes_button.visible = UpdateService.has_notes()
	# Set from code, not left to the scene's own literal, so that every string the
	# launcher owns reaches a translator through a tr() call -- which is what lets
	# ci/make_pot.py find them all by reading the scripts alone, with no list of
	# scene properties to keep in step.
	_notes_button.text = tr("What's new")

	match UpdateService.state:
		UpdateService.State.BINARY_READY:
			_update_button.text = tr("Update app")
		UpdateService.State.CONTENT_READY:
			_update_button.text = tr("Download update")
		UpdateService.State.NEEDS_PERMISSION:
			_update_button.text = tr("Install")
		UpdateService.State.RESTART_REQUIRED:
			_update_button.text = tr("Restart")
		UpdateService.State.CHECKING:
			_update_button.text = tr("Checking…")
		UpdateService.State.DOWNLOADING, UpdateService.State.VERIFYING:
			_update_button.text = tr("Working…")
		_:
			_update_button.text = tr("Check for updates")


func _on_progress_changed(downloaded: int, total: int) -> void:
	if total > 0:
		_progress.max_value = total
		_progress.value = downloaded
		_status_label.text = tr("Downloading… %s of %s") % [
			_format_bytes(downloaded), _format_bytes(total)]
	else:
		# No Content-Length: show motion without a bogus percentage.
		_progress.max_value = 1
		_progress.value = 0
		_status_label.text = tr("Downloading… %s") % _format_bytes(downloaded)


## Shows what the update actually contains before spending a download on it.
func _prompt_update() -> void:
	if UpdateService.pending_notes_text().is_empty():
		# Nothing worth reading; don't make anyone dismiss an empty dialog.
		await UpdateService.apply_pending_update()
		return
	_say_update_prompt()


## Apart from _prompt_update() so that saying it again in another language can
## never take the branch above, which starts the download.
func _say_update_prompt() -> void:
	var notes := UpdateService.pending_notes_text()
	var is_binary := UpdateService.state == UpdateService.State.BINARY_READY
	var size := _format_bytes(int(UpdateService.pending_artifact.get("size", 0)))
	var summary := (tr("New app build · %s") if is_binary else tr("Content update · %s")) % size

	_show_overlay(
		tr("What's new in v%s") % UpdateService.manifest.get("version_name", "?"),
		"%s\n\n%s" % [summary, notes],
		tr("Update now") if is_binary else tr("Download"),
		Callable(self, "_do_apply"),
		tr("Later"), _say_update_prompt)


func _do_apply() -> void:
	await UpdateService.apply_pending_update()


func _prompt_restart() -> void:
	var body := tr("The update is downloaded. The game needs to restart to finish applying it.")
	if OS.has_feature("editor"):
		# The separator stays out of the msgid: a translator should not have to
		# carry leading newlines through their file to keep the layout.
		body += "\n\n" + tr("Running from the editor: stop and play the project again.")
	_show_overlay(tr("Update ready"), body, tr("Restart now"), Callable(self, "_do_restart"),
		tr("Later"), _prompt_restart)


func _do_restart() -> void:
	if UpdateService.restart_app():
		return
	_explain_manual_restart()


func _explain_manual_restart() -> void:
	_show_overlay(
		tr("Restart needed"),
		tr("Close the game and open it again to finish the update."),
		tr("OK"), Callable(self, "_hide_overlay"), "", _explain_manual_restart)


# ---------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------

## The full history, available whether or not an update is pending.
func _show_history() -> void:
	var history := UpdateService.history_text()
	if history.is_empty():
		_show_overlay(
			tr("Patch notes"),
			tr("Nothing recorded yet. Notes arrive with the first successful update check — tap \"Check for updates\" once you're online."),
			tr("Close"), Callable(self, "_hide_overlay"), "", _show_history)
		return
	_show_overlay(tr("Patch notes"), history, tr("Close"),
		Callable(self, "_hide_overlay"), "", _show_history, HISTORY_VIEW_HEIGHT)


## [param resay] shows this same overlay again from scratch -- normally the
## function calling this one. A language change re-runs it, since the strings
## passed here were translated once, on the way in.
##
## [param scroll_height] of 0 lets the dialog size itself to the text; anything
## larger caps it there and scrolls, which is what the long history needs.
func _show_overlay(title: String, body: String, primary_text: String,
		primary_action: Callable, secondary_text: String, resay: Callable,
		scroll_height: float = 0.0) -> void:
	_overlay_resay = resay
	_overlay_title.text = title
	_overlay_body.text = body

	if scroll_height > 0.0:
		_overlay_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		_overlay_scroll.custom_minimum_size.y = scroll_height
	else:
		# Disabled vertical scrolling makes the container report its child's full
		# height, so short dialogs keep hugging their text.
		_overlay_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_overlay_scroll.custom_minimum_size.y = 0.0
	# Saying the same overlay again in another language keeps the reader's place
	# and focus; only a new overlay starts from the top, on its primary button.
	if not _resaying:
		_overlay_scroll.scroll_vertical = 0

	_overlay_primary.text = primary_text
	_overlay_action = primary_action
	_overlay_secondary.text = secondary_text
	_overlay_secondary.visible = not secondary_text.is_empty()
	_overlay.show()
	if not _resaying:
		_overlay_primary.grab_focus()


func _hide_overlay() -> void:
	_overlay.hide()
	_overlay_action = Callable()
	_overlay_resay = Callable()
	if _first_button != null:
		_first_button.grab_focus()


func _on_overlay_primary() -> void:
	var action := _overlay_action
	_hide_overlay()
	if action.is_valid():
		action.call()


func _format_bytes(count: int) -> String:
	if count < 1024:
		return tr("%d B") % count
	if count < 1024 * 1024:
		return tr("%.1f KB") % (count / 1024.0)
	return tr("%.1f MB") % (count / (1024.0 * 1024.0))
