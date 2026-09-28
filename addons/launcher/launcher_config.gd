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

## Follow one branch's rolling prerelease instead of the newest release.
##
## Empty -- the normal case -- polls /releases/latest/download/, so the build
## updates to whatever every player gets.
##
## Set to a branch name, this build polls that branch's own rolling release
## instead, tagged "branch-<name>". CI publishes that release as a prerelease, so
## /releases/latest/ never returns it and no player ever sees it. That is how a
## change gets tried on a real device before it ships.
##
## A build with this set must also be exported with ci/prepare_build.sh's
## RELEASE_BRANCH set to the same branch. That is what gives it its own Android
## package id and its own user:// directory, so it installs beside the real app
## instead of replacing it, and neither app reads the other's saved data.
##
## The name is used verbatim as the tag suffix, so it has to be usable in a git
## tag and in a single URL path segment: letters, digits, dot, underscore and
## hyphen, starting with a letter or digit. A name containing a slash cannot
## work -- it would add a path segment to the download URL -- and is reported
## rather than quietly polling the wrong place.
@export var update_branch: String = ""

## Check for updates automatically when the launcher opens.
@export var check_on_launch: bool = true

## Show the status bar and its buttons along the bottom.
@export var show_update_bar: bool = true

# ---------------------------------------------------------------------------
@export_group("Theme")

## Replaces the launcher's bundled theme wholesale. Leave empty to keep it.
@export var theme_override: Theme


## True when [member update_branch] is empty, or is a name that can be used
## verbatim as a git tag suffix and as one URL path segment.
##
## Mirrors the identical check in ci/prepare_build.sh, which refuses to build for
## a branch this would reject -- so a name that gets a build made for it is a name
## the launcher can poll.
func update_branch_is_valid() -> bool:
	if update_branch.is_empty():
		return true
	# Git refuses all three outright, so the tag could never have been created.
	if update_branch.contains(".."):
		return false
	if update_branch.ends_with(".") or update_branch.ends_with(".lock"):
		return false
	for i in update_branch.length():
		var c := update_branch.unicode_at(i)
		var alnum := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
		if i == 0:
			if not alnum:
				return false
		# . _ -
		elif not (alnum or c == 46 or c == 95 or c == 45):
			return false
	return true


## The release tag this build follows, or "" when it follows /releases/latest/.
##
## Also "" for a branch name this launcher will not poll, so the tag a caller
## gets is always one that could exist.
func release_tag() -> String:
	if update_branch.is_empty() or not update_branch_is_valid():
		return ""
	return "branch-" + update_branch


## Why updates cannot run, or "" when they can.
func update_config_error() -> String:
	if update_repo.is_empty():
		return "No update repository configured (set update_repo in the launcher config)."
	if not update_branch_is_valid():
		return ("update_branch \"%s\" is not a usable branch name: letters, digits, dot, "
			+ "underscore and hyphen only, starting with a letter or digit.") % update_branch
	return ""


## Where the app polls for its update manifest.
##
## With no branch set, /releases/latest/download/ always redirects to the newest
## release, so a shipped build never needs a release tag, an API call, or a rate
## limit budget.
##
## With one set, the URL is pinned to that branch's rolling tag instead. The name
## is still fixed from one build to the next -- the tag rolls, it does not change
## -- so the same reasoning holds.
##
## Returns "" when the branch name is unusable. Deliberately not a fall back to
## /releases/latest/: that would have a branch build quietly start updating
## itself from the releases players get, which is the one thing it must not do.
func manifest_url() -> String:
	if update_repo.is_empty() or not update_branch_is_valid():
		return ""
	var tag := release_tag()
	if tag.is_empty():
		return "https://github.com/%s/releases/latest/download/manifest.json" % update_repo
	return "https://github.com/%s/releases/download/%s/manifest.json" % [update_repo, tag]


func releases_url() -> String:
	if update_repo.is_empty() or not update_branch_is_valid():
		return ""
	var tag := release_tag()
	if tag.is_empty():
		return "https://github.com/%s/releases/latest" % update_repo
	return "https://github.com/%s/releases/tag/%s" % [update_repo, tag]


func updates_enabled() -> bool:
	return not update_repo.is_empty()


## Fills the tagline placeholders. Returns "" when there is no tagline to show.
func resolved_tagline(version_name: String, content_version: int) -> String:
	if tagline.is_empty():
		return ""
	return tagline.replace("{build}", str(content_version)).replace("{version}", version_name)
