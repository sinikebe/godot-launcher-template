#!/usr/bin/env bash
# Turns a fresh copy of the launcher template into your own game, in one go.
#
#   bash ci/new_game.sh "My Game" com.example.mygame you/my-game
#
# It moves the starter files into place, deletes the demo scaffolding, and
# writes your name, your Android package id and your repository everywhere they
# belong. Run it once, right after creating your repository from the template.
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: bash ci/new_game.sh [--delete-licence] "<Game Name>" <android.package.id> [owner/repo]

  <Game Name>          shown on the launcher, e.g. "Deep Cavern"
  <android.package.id> unique id for your app, e.g. com.yourname.deepcavern
                       Must not collide with any other app on a device.
  [owner/repo]         your GitHub repo, e.g. you/deep-cavern
                       Detected from `git remote` when omitted.

  --delete-licence     Delete the root LICENSE. It arrives from the template
                       and carries the template author's copyright, so it is
                       wrong for your game -- but this script will not guess
                       whether you have already replaced it with your own.
                       Pass this and it is deleted; leave it off and you are
                       told to replace it. Either way the launcher keeps its
                       own MIT licence in addons/launcher/ and ci/.
                       --delete-license is accepted too.
USAGE
}

DELETE_LICENCE=false
ARGS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--delete-licence|--delete-license) DELETE_LICENCE=true; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; ARGS+=("$@"); break ;;
		-*) echo "error: unknown option '$1'" >&2; usage >&2; exit 1 ;;
		*) ARGS+=("$1"); shift ;;
	esac
done
# The +"..." guard keeps `set -u` happy when no positionals were given at all.
set -- ${ARGS[@]+"${ARGS[@]}"}

GAME_NAME="${1:-}"
PACKAGE_ID="${2:-}"
REPO="${3:-}"

if [[ -z "$GAME_NAME" || -z "$PACKAGE_ID" ]]; then
	usage >&2
	exit 1
fi

if [[ ! "$PACKAGE_ID" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]]; then
	echo "error: '$PACKAGE_ID' is not a valid Android package id." >&2
	echo "       Use at least two lowercase parts, e.g. com.yourname.yourgame" >&2
	exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

if [[ -z "$REPO" ]]; then
	REPO="$(git remote get-url origin 2>/dev/null \
		| sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##' || true)"
fi
if [[ -z "$REPO" ]]; then
	echo "error: could not detect your repository; pass it as the third argument." >&2
	exit 1
fi

# Describes the root LICENSE from what is on disk. Never assert what it
# contains: a developer may already have replaced it, and a summary that
# contradicts the filesystem is worse than no summary.
licence_line() {
	if [[ -d LICENSE ]]; then
		printf 'a directory, not a file'
	elif [[ -L LICENSE && ! -e LICENSE ]]; then
		printf 'a symlink pointing nowhere'
	elif [[ ! -e LICENSE ]]; then
		printf 'absent'
	elif [[ ! -r LICENSE ]]; then
		printf 'present but unreadable'
	else
		local line
		line="$(grep -m1 -i copyright LICENSE 2>/dev/null | tr -d '\r' | tr -cd '\11\40-\176' || true)"
		printf '%s' "${line:-present, with no copyright line}"
	fi
}

if [[ ! -d template ]]; then
	# No template/ here. That means setup already ran -- or this was never a
	# fresh template copy at all: an existing game that adopted the launcher by
	# hand, a repository the launcher was synced into, a parent repo the caller
	# happened to be standing in. This branch MUST NOT delete anything. It once
	# did, and it deleted the licence of whichever repository ran it.
	echo "Starter files already moved -- nothing to do. Edit version.json and"
	echo "launcher_config.tres directly if you want to rename the game."
	if [[ -e LICENSE || -L LICENSE ]]; then
		echo
		echo "The root LICENSE is $(licence_line)."
		echo "If that is still the template's, it covers the launcher and not your"
		echo "game -- replace it, or delete it yourself with: rm LICENSE"
		echo "--delete-licence only applies while setting a game up, so that this"
		echo "script can never remove a licence in a repository it did not create."
	fi
	exit 0
fi

echo "Setting up '${GAME_NAME}' (${PACKAGE_ID}) for ${REPO}…"

# The workflows are already at .github/workflows/ in a repo made from the
# template; only the export presets need putting in place, replacing the demo's.
mv -f template/export_presets.cfg export_presets.cfg
rm -rf template

python3 - "$GAME_NAME" "$PACKAGE_ID" "$REPO" <<'PY'
import json
import pathlib
import re
import sys

game_name, package_id, repo = sys.argv[1:4]

# The name the release pipeline derives every artifact name from.
version = pathlib.Path("version.json")
data = json.loads(version.read_text(encoding="utf-8"))
data["game_name"] = game_name
data["version_name"] = "0.1.0"
data["binary_version"] = 1
version.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

# Android identity. A duplicate package id collides with whatever else is using
# it, and then neither app can update the other -- so this one really matters.
presets = pathlib.Path("export_presets.cfg")
text = presets.read_text(encoding="utf-8")
text = re.sub(r'^package/unique_name=".*"$', f'package/unique_name="{package_id}"', text, flags=re.M)
for key in ("package/name", "application/product_name", "application/file_description"):
    text = re.sub(rf'^{re.escape(key)}=".*"$', f'{key}="{game_name}"', text, flags=re.M)
presets.write_text(text, encoding="utf-8")

# What the launcher shows, and which repository it polls for updates.
config = pathlib.Path("launcher_config.tres")
text = config.read_text(encoding="utf-8")
text = re.sub(r'^game_title = ".*"$', f'game_title = "{game_name}"', text, flags=re.M)
text = re.sub(r'^update_repo = ".*"$', f'update_repo = "{repo}"', text, flags=re.M)
config.write_text(text, encoding="utf-8")

project = pathlib.Path("project.godot")
text = project.read_text(encoding="utf-8")
text = re.sub(r'^config/name=".*"$', f'config/name="{game_name}"', text, flags=re.M)
project.write_text(text, encoding="utf-8")
PY

# The root LICENSE, only if you asked for it.
#
# It arrives from the template carrying the template author's copyright, so it
# is wrong for your game -- but the script cannot tell whether you have already
# replaced it with your own, and every rule for guessing is wrong in some real
# case. So it does not guess: --delete-licence is you stating the answer.
#
# Last, after every edit above has succeeded, so an aborted run cannot leave a
# repository that is both half-configured and missing its licence.
#
# The launcher's own terms are not at stake either way: they live in
# addons/launcher/LICENSE and ci/LICENSE, with the code they cover.
LICENSE_LINE=""
if [[ "$DELETE_LICENCE" == true ]]; then
	# Run outside any command substitution, so a failing rm actually stops the
	# script instead of being swallowed while the summary claims success.
	if [[ -e LICENSE || -L LICENSE ]]; then
		rm -f LICENSE
		LICENSE_LINE="
  LICENSE               deleted, as --delete-licence asked"
		LICENSE_NEXT="
  0. Add your own LICENSE -- the repository has none now."
	else
		LICENSE_LINE="
  LICENSE               nothing to delete; there was none"
		LICENSE_NEXT="
  0. Add a LICENSE -- the repository has none."
	fi
elif [[ -e LICENSE || -L LICENSE ]]; then
	LICENSE_NEXT="
  0. Replace LICENSE. The root one is $(licence_line) -- if that is the
     template's, it covers the launcher and not your game. Put your own terms
     there, or set up again with --delete-licence to drop it. The launcher
     keeps its own MIT licence in addons/launcher/LICENSE and ci/LICENSE;
     leave those alone."
else
	LICENSE_NEXT="
  0. Add a LICENSE -- the repository has none."
fi

cat <<EOF

Done. Changed:
  version.json          game_name          -> ${GAME_NAME}
  export_presets.cfg    package id         -> ${PACKAGE_ID}
  launcher_config.tres  title, update_repo -> ${REPO}
  project.godot         project name
  template/             removed${LICENSE_LINE}

Next:${LICENSE_NEXT}
  1. git add -A && git commit -m "Set up ${GAME_NAME}" && git push
  2. Enable Settings -> Actions -> General ->
     "Allow GitHub Actions to create and approve pull requests"
  3. Wait for the Release workflow, then check your Releases page.

  docs/GETTING-STARTED.md has the rest, including Android signing.
EOF
