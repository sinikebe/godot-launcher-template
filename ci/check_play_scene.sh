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
# Three things that look like errors are not counted. The report Godot's editor and
# debug builds print as the process exits, of objects and RIDs a scene left behind,
# is made of ERROR: lines a player never sees, and a game that orphans a node would
# fail on it while running fine. Warnings are not errors. And a line that does not
# begin with the word, because the game printed something without a newline first
# (printraw), is not seen: the anchor is what keeps a game's own prints from failing
# the check, and the cost is that one.
#
# What it cannot see: --quit-after counts frames, so about a second of the scene's
# life is run. That covers _ready() and what follows it at once, not an error
# behind a long timer. And it boots the scene directly, so the launcher's own Play
# path is not involved: the fade, the hooks and the scene change itself. It also
# runs headless, with no window, display or save data, so code that assumes any of
# them logs errors here that a player's device would not (docs/TROUBLESHOOTING.md).
#
# Two guards against a scene that is not what it seems. --quit-after is reached only
# by a scene that yields, so a loop in _ready() would hold the job for GitHub's six
# hours; PLAY_SCENE_TIMEOUT (seconds, default below) ends it. And Godot reads a
# positional argument as a scene only when it ends in .tscn, .scn, .escn or .res:
# anything else is ignored and the main scene booted instead, exit status 0, so a
# play_scene with the wrong extension is refused rather than passed unrun.
#
# Needs the project imported first (ci.yml's "Import project" step runs before it)
# and Godot at GODOT, which defaults to where ci/install_godot.sh puts it. Run in a
# scratch HOME, as ci.yml's other boots are, so user:// starts empty.
set -euo pipefail

# Before HOME is replaced below.
GODOT="${GODOT:-$HOME/godot/godot}"
# Frames, not seconds. See above.
QUIT_AFTER=120
# Seconds. --quit-after is only reached by a scene that yields: one that loops forever
# in _ready(), or waits on something that never comes, would otherwise hold the job
# until GitHub's six-hour limit. A healthy scene needs about a second.
RUN_TIMEOUT="${PLAY_SCENE_TIMEOUT:-120}"

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

# Godot's command line takes a positional argument as a scene only when it ends in .tscn,
# .scn, .escn or .res. Anything else is ignored and the MAIN scene is booted instead, with
# exit status 0 and nothing logged: a play_scene missing its extension would pass, unrun.
if [[ "$SCENE" == res://* && ! "$SCENE" =~ \.(tscn|scn|escn|res)$ ]]; then
	echo "::error::play_scene in ${CONFIG} is '${SCENE}', which does not end in .tscn, .scn, .escn or .res. Godot would not run it, so the check would pass without booting it." >&2
	exit 1
fi

if ! command -v "$GODOT" >/dev/null 2>&1; then
	echo "::error::Godot is not at ${GODOT}. Set GODOT, or run ci/install_godot.sh first." >&2
	exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

echo "Booting ${SCENE} for ${QUIT_AFTER} frames."
guard=()
if command -v timeout >/dev/null 2>&1; then
	guard=(timeout --kill-after=10 "$RUN_TIMEOUT")
fi
status=0
out="$(HOME="$scratch" XDG_DATA_HOME="$scratch/data" XDG_CONFIG_HOME="$scratch/config" XDG_CACHE_HOME="$scratch/cache" \
	${guard[@]+"${guard[@]}"} "$GODOT" --headless --path . "$SCENE" --quit-after "$QUIT_AFTER" 2>&1)" || status=$?
printf '%s\n' "$out"

if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
	echo "::error::${SCENE} was still running after ${RUN_TIMEOUT} seconds. A loop in it never ends, or something in _ready() waits for what will not come." >&2
	exit 1
fi
if [[ "$status" -ne 0 ]]; then
	echo "::error::${SCENE} could not be run: Godot exited with status ${status}." >&2
	exit 1
fi
# Not counted: the report Godot's editor and debug builds print as the process exits, of
# objects and RIDs the scene left behind. It says nothing a player sees, and a game that
# orphans a Node with a script, or keeps a server RID, would fail on it while running fine.
logged="$(grep -E '^((SCRIPT|SHADER) )?ERROR:' <<<"$out" || true)"
errors="$(grep -vE '^ERROR: ([0-9]+ resources still in use at exit|[0-9]+ RID allocations of type .* were leaked at exit)' <<<"$logged" || true)"
if [[ -n "$errors" ]]; then
	echo "::error::${SCENE} logged errors when it ran headless, listed above. See docs/TROUBLESHOOTING.md, \"The CI check on Play's scene fails\"." >&2
	exit 1
fi
if [[ -n "$logged" ]]; then
	echo "Not counted: the ERROR lines above that report what the scene left behind as Godot exited."
fi
echo "${SCENE} ran without logging an error."
