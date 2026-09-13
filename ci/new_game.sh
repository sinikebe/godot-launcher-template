#!/usr/bin/env bash
# Turns a fresh copy of the launcher template into your own game, in one go.
#
#   bash ci/new_game.sh "My Game" com.example.mygame you/my-game
#
# It moves the starter files into place, deletes the demo scaffolding, and
# writes your name, your Android package id and your repository everywhere they
# belong. Run it once, right after creating your repository from the template.
set -euo pipefail

GAME_NAME="${1:-}"
PACKAGE_ID="${2:-}"
REPO="${3:-}"

if [[ -z "$GAME_NAME" || -z "$PACKAGE_ID" ]]; then
	cat >&2 <<'USAGE'
Usage: bash ci/new_game.sh "<Game Name>" <android.package.id> [owner/repo]

  <Game Name>          shown on the launcher, e.g. "Deep Cavern"
  <android.package.id> unique id for your app, e.g. com.yourname.deepcavern
                       Must not collide with any other app on a device.
  [owner/repo]         your GitHub repo, e.g. you/deep-cavern
                       Detected from `git remote` when omitted.
USAGE
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

if [[ ! -d template ]]; then
	echo "Starter files already moved -- nothing to do. Edit version.json and"
	echo "launcher_config.tres directly if you want to rename the game."
	exit 0
fi

echo "Setting up '${GAME_NAME}' (${PACKAGE_ID}) for ${REPO}…"

mkdir -p .github/workflows
mv template/.github/workflows/*.yml .github/workflows/
mv template/export_presets.cfg export_presets.cfg
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

cat <<EOF

Done. Changed:
  version.json          game_name      -> ${GAME_NAME}
  export_presets.cfg    package id     -> ${PACKAGE_ID}
  launcher_config.tres  title, update_repo -> ${REPO}
  project.godot         project name
  template/             moved into place and removed

Next:
  1. git add -A && git commit -m "Set up ${GAME_NAME}" && git push
  2. Enable Settings -> Actions -> General ->
     "Allow GitHub Actions to create and approve pull requests"
  3. Wait for the Release workflow, then check your Releases page.

  docs/GETTING-STARTED.md has the rest, including Android signing.
EOF
