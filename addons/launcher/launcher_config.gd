@tool
class_name LauncherConfig
extends Resource
## Everything a project changes about its launcher, in one resource.
##
## Create one per game (`res://launcher_config.tres` by default) and point the
## `launcher/config_path` project setting at it if you keep it somewhere else.
## Nothing in addons/launcher/ should need editing to reskin a launcher -- that
## directory is overwritten wholesale whenever the launcher template updates.

# ---------------------------------------------------------------------------
@export_group("Identity")

## Shown large at the top of the launcher.
@export var game_title: String = "YOUR GAME"

## Line under the title. Supports two placeholders, filled in at runtime:
## [code]{build}[/code] -> content version, [code]{version}[/code] -> version name.
## Leave empty to hide the line entirely.
@export var tagline: String = "build {build} · updates itself"

# ---------------------------------------------------------------------------
@export_group("Background")

## Drawn behind everything. Takes priority over [member background_shader].
@export var background_texture: Texture2D

## Used when no texture is set. The bundled organic shader is the default.
@export var background_shader: Shader

## Flat fill behind texture and shader; also the whole background if neither is set.
@export var background_color: Color = Color(0.023, 0.055, 0.05)

## How a background texture fills the screen. Defaults to a centred cover crop,
## which is almost always what you want for a full-bleed image.
@export_enum("Scale", "Tile", "Keep Centered", "Cover", "Contain")
var background_stretch: int = 3

## Black veil over the background, 0-1. Raise it when a busy photo is fighting
## the menu text for attention.
@export_range(0.0, 1.0, 0.01) var background_dim: float = 0.0

# ---------------------------------------------------------------------------
@export_group("Layout")

## Distance from the screen edge for the title, the menu and the update bar.
@export_range(0, 200) var edge_margin: int = 48

@export_enum("Left", "Center", "Right") var title_h_align: int = 0
@export_enum("Top", "Center", "Bottom") var title_v_align: int = 0

@export_enum("Left", "Center", "Right") var menu_h_align: int = 1
@export_enum("Top", "Center", "Bottom") var menu_v_align: int = 1

## Width of the button column. Ignored when the menu is horizontal.
@export_range(80, 800) var menu_width: int = 300

@export_enum("Vertical", "Horizontal") var menu_orientation: int = 0

@export_range(0, 64) var menu_separation: int = 12

# ---------------------------------------------------------------------------
@export_group("Buttons")

@export var show_play: bool = true
@export var play_text: String = "Play"

@export var show_quit: bool = true
@export var quit_text: String = "Quit"

## Extra buttons, in order, by label. Pressing one emits
## [signal Launcher.custom_button_pressed] with that label, so a game can wire
## up Settings or Credits without touching the launcher.
@export var extra_buttons: PackedStringArray = PackedStringArray()

# ---------------------------------------------------------------------------
@export_group("Game")

## Scene that Play loads. While empty, Play explains itself instead of failing.
@export_file("*.tscn") var play_scene: String = ""

# ---------------------------------------------------------------------------
@export_group("Updates")

## GitHub repository publishing this game's releases, as "owner/name".
## This is the game's OWN repo, not the launcher template's. Leave empty to
## turn the updater off entirely.
@export var update_repo: String = ""

## Check for updates automatically when the launcher opens.
@export var check_on_launch: bool = true

## Show the status bar and its buttons along the bottom.
@export var show_update_bar: bool = true

# ---------------------------------------------------------------------------
@export_group("Theme")

## Replaces the launcher's bundled theme wholesale. Leave empty to keep it.
@export var theme_override: Theme


## Where the app polls for its update manifest.
##
## /releases/latest/download/ always redirects to the newest release, so a
## shipped build never needs a release tag, an API call, or a rate limit budget.
func manifest_url() -> String:
	if update_repo.is_empty():
		return ""
	return "https://github.com/%s/releases/latest/download/manifest.json" % update_repo


func releases_url() -> String:
	if update_repo.is_empty():
		return ""
	return "https://github.com/%s/releases/latest" % update_repo


func updates_enabled() -> bool:
	return not update_repo.is_empty()


## Fills the tagline placeholders. Returns "" when there is no tagline to show.
func resolved_tagline(version_name: String, content_version: int) -> String:
	if tagline.is_empty():
		return ""
	return tagline.replace("{build}", str(content_version)).replace("{version}", version_name)
