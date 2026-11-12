#!/usr/bin/env bash
# Boots the scene that Play loads, and fails when it logs an error.
#
# ci.yml's other boot runs the main scene, which is the launcher. A game's own
# scenes are reached only through Play, so nothing ever executed them: an export
# packs a broken one without complaint, and the first player to press Play found
# the failure (#30). This runs play_scene the way Godot would on its own, headless,
# so a runtime error in a scene's _ready() fails the pull request instead.
#
# play_scene is read from the launcher config, found as BuildInfo finds it:
# project.godot's launcher/config_path, or launcher_config.tres. Nothing is run
# while it is empty, which is how a game starts out. A game that takes Play over
# with play_requested and leaves play_scene empty is not covered: there is no
# scene here to name. A play_scene set only in a LauncherConfig subclass's script,
# and not in the config file, is not seen either.
#
# Godot exits 0 after a runtime error. A null @onready, a bad preload, a typed
# assignment that does not fit and a failed assert all print their error and carry
# on, so the exit status proves nothing (#71) and the output is read as well. It is
# scanned for ERROR: as well as SCRIPT ERROR:, because a scene that names a missing
# file in an [ext_resource] logs only the former. A game's own push_error() in
# _ready() therefore fails the check too, which is the point of a check that fails
# on what the scene logs.
#
# What it cannot see: --quit-after counts frames, so about a second of the scene's
# life is run. That covers _ready() and what follows it at once, not an error
# behind a long timer. And it boots the scene directly, so the launcher's own Play
# path is not involved: the fade, the hooks and the scene change itself.
#
# Needs the project imported first (ci.yml's "Import project" step runs before it)
# and Godot at GODOT, which defaults to where ci/install_godot.sh puts it. Run in a
# scratch HOME, as ci.yml's other boots are, so user:// starts empty.
set -euo pipefail

# Before HOME is replaced below.
GODOT="${GODOT:-$HOME/godot/godot}"
# Frames, not seconds. See above.
QUIT_AFTER=120

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The config the build reads: project.godot's launcher/config_path, as BuildInfo
# reads it, or the default. The same lookup as ci/prepare_build.sh, except that a
# project.godot that is missing or has no such line is not an error: under pipefail
# it would end the script here without a word.
CONFIG="$(sed -n 's|^config_path="res://\(.*\)"$|\1|p' project.godot 2>/dev/null | head -1 || true)"
CONFIG="${CONFIG:-launcher_config.tres}"

SCENE=""
if [[ -f "$CONFIG" ]]; then
	# Tolerant of how the line is written: by the inspector with spaces around the
	# equals sign, by hand without them, and with Windows line endings.
	SCENE="$(sed -n 's/^play_scene *= *"\([^"]*\)".*/\1/p' "$CONFIG" | head -1 || true)"
fi
if [[ -z "$SCENE" ]]; then
	echo "play_scene is empty in ${CONFIG}, so there is no scene to boot."
	exit 0
fi

# Godot reads anything else as an option, and Play loads nothing but a scene path.
if [[ ! "$SCENE" =~ ^(res|uid):// ]]; then
	echo "::error::play_scene in ${CONFIG} is '${SCENE}', which is not a res:// or uid:// path." >&2
	exit 1
fi

if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "::error::Godot is not at ${GODOT}. Set GODOT, or run ci/install_godot.sh first." >&2
	exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

echo "Booting ${SCENE} for ${QUIT_AFTER} frames."
status=0
out="$(HOME="$scratch" XDG_DATA_HOME="$scratch/data" XDG_CONFIG_HOME="$scratch/config" XDG_CACHE_HOME="$scratch/cache" \
	"$GODOT" --headless --path . "$SCENE" --quit-after "$QUIT_AFTER" 2>&1)" || status=$?
printf '%s\n' "$out"

if [[ "$status" -ne 0 ]]; then
	echo "::error::${SCENE} could not be run: Godot exited with status ${status}." >&2
	exit 1
fi
if grep -qE '^(SCRIPT )?ERROR:' <<<"$out"; then
	echo "::error::${SCENE} logged errors when it ran. Play would show a player the same." >&2
	exit 1
fi
echo "${SCENE} ran without logging an error."
