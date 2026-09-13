extends Control
## The launcher screen. Everything it shows comes from [LauncherConfig]; nothing
## in this file should need editing to reskin a game's launcher.
##
## Update logic lives in UpdateService; this file only drives the UI.

## Emitted when one of [member LauncherConfig.extra_buttons] is pressed, with
## that button's label. Connect it from your own scene to add Settings, Credits
## or anything else without modifying the launcher.
signal custom_button_pressed(label: String)

## Emitted just before Play changes scene, or instead of it when no play scene
## is configured. Lets a game take over the Play action entirely.
signal play_requested()

## Height the patch-note history is capped at before it starts scrolling.
const HISTORY_VIEW_HEIGHT := 300.0

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


func _ready() -> void:
	_config = BuildInfo.config

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

	if _first_button != null:
		_first_button.grab_focus()
	_apply_layout.call_deferred()

	if _config.check_on_launch and _config.updates_enabled():
		# Let the launcher paint before touching the network.
		await get_tree().create_timer(0.4).timeout
		await UpdateService.check_for_updates()


# ---------------------------------------------------------------------------
# Appearance
# ---------------------------------------------------------------------------

func _apply_identity() -> void:
	_title.text = _config.game_title
	var tagline := _config.resolved_tagline(BuildInfo.version_name, BuildInfo.content_version)
	_tagline.text = tagline
	_tagline.visible = not tagline.is_empty()


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
		_show_overlay(
			"Not wired up yet",
			"This is where the game starts. Set play_scene in the launcher config, "
			+ "or connect the launcher's play_requested signal to take over.",
			"OK", Callable(self, "_hide_overlay"), "")
		return
	get_tree().change_scene_to_file(_config.play_scene)


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
			_show_overlay(
				"Installing",
				"Confirm the update in the system installer. The game will reopen "
				+ "on the new version once the install finishes.",
				"OK", Callable(self, "_hide_overlay"), "")
		_:
			pass


func _refresh_update_ui() -> void:
	_status_label.text = UpdateService.status_text()

	var busy := UpdateService.state in [
		UpdateService.State.CHECKING,
		UpdateService.State.DOWNLOADING,
		UpdateService.State.VERIFYING,
	]
	_progress.visible = UpdateService.state == UpdateService.State.DOWNLOADING
	_update_button.disabled = busy

	match UpdateService.state:
		UpdateService.State.BINARY_READY:
			_update_button.text = "Update app"
		UpdateService.State.CONTENT_READY:
			_update_button.text = "Download update"
		UpdateService.State.NEEDS_PERMISSION:
			_update_button.text = "Install"
		UpdateService.State.RESTART_REQUIRED:
			_update_button.text = "Restart"
		UpdateService.State.CHECKING:
			_update_button.text = "Checking…"
		UpdateService.State.DOWNLOADING, UpdateService.State.VERIFYING:
			_update_button.text = "Working…"
		_:
			_update_button.text = "Check for updates"


func _on_progress_changed(downloaded: int, total: int) -> void:
	if total > 0:
		_progress.max_value = total
		_progress.value = downloaded
		_status_label.text = "Downloading… %s of %s" % [
			_format_bytes(downloaded), _format_bytes(total)]
	else:
		# No Content-Length: show motion without a bogus percentage.
		_progress.max_value = 1
		_progress.value = 0
		_status_label.text = "Downloading… %s" % _format_bytes(downloaded)


## Shows what the update actually contains before spending a download on it.
func _prompt_update() -> void:
	var notes := UpdateService.pending_notes_text()
	if notes.is_empty():
		# Nothing worth reading; don't make anyone dismiss an empty dialog.
		await UpdateService.apply_pending_update()
		return

	var is_binary := UpdateService.state == UpdateService.State.BINARY_READY
	var size := _format_bytes(int(UpdateService.pending_artifact.get("size", 0)))
	var summary := ("New app build · %s" if is_binary else "Content update · %s") % size

	_show_overlay(
		"What's new in v%s" % UpdateService.manifest.get("version_name", "?"),
		"%s\n\n%s" % [summary, notes],
		"Update now" if is_binary else "Download",
		Callable(self, "_do_apply"),
		"Later")


func _do_apply() -> void:
	await UpdateService.apply_pending_update()


func _prompt_restart() -> void:
	var body := "The update is downloaded. The game needs to restart to finish applying it."
	if OS.has_feature("editor"):
		body += "\n\nRunning from the editor: stop and play the project again."
	_show_overlay("Update ready", body, "Restart now", Callable(self, "_do_restart"), "Later")


func _do_restart() -> void:
	if UpdateService.restart_app():
		return
	_show_overlay(
		"Restart needed",
		"Close the game and open it again to finish the update.",
		"OK", Callable(self, "_hide_overlay"), "")


# ---------------------------------------------------------------------------
# Overlay
# ---------------------------------------------------------------------------

## The full history, available whether or not an update is pending.
func _show_history() -> void:
	var history := UpdateService.history_text()
	if history.is_empty():
		_show_overlay(
			"Patch notes",
			"Nothing recorded yet. Notes arrive with the first successful update "
			+ "check — tap \"Check for updates\" once you're online.",
			"Close", Callable(self, "_hide_overlay"), "")
		return
	_show_overlay("Patch notes", history, "Close",
		Callable(self, "_hide_overlay"), "", HISTORY_VIEW_HEIGHT)


## [param scroll_height] of 0 lets the dialog size itself to the text; anything
## larger caps it there and scrolls, which is what the long history needs.
func _show_overlay(title: String, body: String, primary_text: String,
		primary_action: Callable, secondary_text: String,
		scroll_height: float = 0.0) -> void:
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
	_overlay_scroll.scroll_vertical = 0

	_overlay_primary.text = primary_text
	_overlay_action = primary_action
	_overlay_secondary.text = secondary_text
	_overlay_secondary.visible = not secondary_text.is_empty()
	_overlay.show()
	_overlay_primary.grab_focus()


func _hide_overlay() -> void:
	_overlay.hide()
	_overlay_action = Callable()
	if _first_button != null:
		_first_button.grab_focus()


func _on_overlay_primary() -> void:
	var action := _overlay_action
	_hide_overlay()
	if action.is_valid():
		action.call()


func _format_bytes(count: int) -> String:
	if count < 1024:
		return "%d B" % count
	if count < 1024 * 1024:
		return "%.1f KB" % (count / 1024.0)
	return "%.1f MB" % (count / (1024.0 * 1024.0))
