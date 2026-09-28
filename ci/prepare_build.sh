#!/usr/bin/env bash
# Stamps this build's identity into the places that need it before export:
#
#   1. build_version.gd     -- what the running app reports, and what it
#      compares against the manifest to decide whether an update applies.
#   2. export_presets.cfg       -- Android versionCode / versionName.
#
# With RELEASE_BRANCH set, this build follows that branch's rolling prerelease
# instead of /releases/latest/, and has to be able to sit on a device next to the
# real app rather than replacing it. Two more places are stamped for that:
#
#   3. export_presets.cfg again -- the Android package id gains a branch segment
#      and the app names gain a "(branch)" label, so Android treats it as a
#      different app and a human can tell the two icons apart.
#   4. project.godot            -- a custom user dir, so the branch build and the
#      release build never read each other's saves, settings or staged content
#      packs. On Android the package id already separates them; this is what
#      separates them everywhere else.
#
# Every edit is made to the checkout being built and none is ever committed.
#
# Prints the computed values, and writes them to $GITHUB_OUTPUT when running
# under GitHub Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Artifact names derive from the game's name so a project only states it once.
# They must stay stable across releases: the app fetches them through
# /releases/latest/download/<name>, which only resolves for a fixed name.
# One value per line, because a game name may contain spaces.
mapfile -t _DERIVED < <(python3 - <<'PYEOF'
import json, re

with open("version.json", encoding="utf-8") as fh:
    name = str(json.load(fh).get("game_name", "Game")).strip() or "Game"
slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "game"
exe = re.sub(r"[^A-Za-z0-9]+", "", name) or "Game"
print(name)
print(slug)
print(f"{slug}.apk")
print(f"{exe}.exe")
PYEOF
)
GAME_NAME="${_DERIVED[0]}"
GAME_SLUG="${_DERIVED[1]}"
APK_NAME="${_DERIVED[2]}"
EXE_NAME="${_DERIVED[3]}"

VERSION_NAME="$(python3 -c 'import json;print(json.load(open("version.json",encoding="utf-8"))["version_name"])')"
BINARY_VERSION="$(python3 -c 'import json;print(int(json.load(open("version.json",encoding="utf-8"))["binary_version"]))')"

# Commit count is monotonic on main and moves on every merge, which is exactly
# the property a content version needs.
CONTENT_VERSION="$(git rev-list --count HEAD)"
COMMIT="$(git rev-parse --short=8 HEAD)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Empty -- the normal case -- builds exactly what it always did: a release that
# /releases/latest/ serves to every player.
RELEASE_BRANCH="${RELEASE_BRANCH:-}"

if [[ -n "$RELEASE_BRANCH" ]]; then
	# Mirrors LauncherConfig.update_branch_is_valid(). The name is used verbatim as
	# a git tag suffix and as one URL path segment, so a slash cannot work, and a
	# name git would refuse must be caught here rather than at `gh release create`
	# after a twenty-minute build.
	if [[ ! "$RELEASE_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
		|| [[ "$RELEASE_BRANCH" == *..* ]] \
		|| [[ "$RELEASE_BRANCH" == *. ]] \
		|| [[ "$RELEASE_BRANCH" == *.lock ]]; then
		echo "::error::RELEASE_BRANCH is not a usable branch name for a rolling release." >&2
		printf '%s\n' \
			"Letters, digits, dot, underscore and hyphen only, starting with a letter" \
			"or digit, no \"..\", and not ending in \".\" or \".lock\"." \
			"" \
			"The name becomes the tag \"branch-<name>\" and one segment of the URL the" \
			"app polls, and LauncherConfig.update_branch applies the same rule -- so a" \
			"name accepted here is a name the shipped build can actually poll." >&2
		exit 1
	fi

	# Android package segments are [A-Za-z_][A-Za-z0-9_]*: no dots, no hyphens, and
	# no leading digit. So the branch name is mapped for that use rather than
	# inserted. The mapping does not have to agree with the tag -- nothing outside
	# the APK ever reads the package id.
	mapfile -t _BRANCH < <(python3 - <<'PYEOF'
import os, re

branch = os.environ["RELEASE_BRANCH"]
segment = re.sub(r"[^a-z0-9]+", "_", branch.lower()).strip("_") or "branch"
if not segment[0].isalpha():
    segment = "b" + segment
print(segment)
# Same idea for a directory name, where a hyphen reads better than an underscore.
print(re.sub(r"[^a-z0-9]+", "-", branch.lower()).strip("-") or "branch")
PYEOF
	)
	BRANCH_PACKAGE_SEGMENT="${_BRANCH[0]}"
	BRANCH_SLUG="${_BRANCH[1]}"
	# The rolling tag: it is refreshed in place on every push to the branch, so the
	# URL the branch build polls is fixed even though its contents change.
	TAG="branch-${RELEASE_BRANCH}"
else
	BRANCH_PACKAGE_SEGMENT=""
	BRANCH_SLUG=""
	TAG="v${VERSION_NAME}+${CONTENT_VERSION}"
fi

IS_CI_BUILD=false
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
	IS_CI_BUILD=true
fi

# This build's own patch notes, baked in so the app can describe itself without
# a network round trip -- offline, or before it has ever checked for updates.
# Written by ci/collect_changes.sh, which must therefore run first.
CHANGES_LITERAL="$(python3 - <<'PY'
import json, os

items = []
path = "build/notes/changes.json"
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            items = [str(x) for x in json.load(fh)][:20]
    except (ValueError, OSError):
        items = []
# json.dumps produces string literals GDScript accepts verbatim.
print("[" + ", ".join(json.dumps(i, ensure_ascii=False) for i in items) + "]")
PY
)"

cat > build_version.gd <<EOF
extends RefCounted
## GENERATED BY ci/prepare_build.sh -- do not edit by hand.
##
## The committed copy of this file holds the local-dev defaults (version 0), so
## a build made outside CI always considers itself older than any release and
## will offer to update. CI overwrites it in the workspace immediately before
## exporting, so the shipped APK/EXE and the shipped content pack each carry the
## versions they were actually built with.

## Bumped by hand in version.json. A release advertising a higher value than the
## installed one needs a new APK/EXE -- a content pack cannot deliver it.
const BINARY_VERSION: int = ${BINARY_VERSION}

## Bumped automatically on every release. A higher value alone can be delivered
## as a content pack.
const CONTENT_VERSION: int = ${CONTENT_VERSION}

## Cosmetic, shown in the UI.
const VERSION_NAME: String = "${VERSION_NAME}"

## Short commit SHA this build came from, or "local" outside CI.
const COMMIT: String = "${COMMIT}"

## RFC3339 build timestamp, or "" outside CI.
const BUILT_AT: String = "${BUILT_AT}"

## True when this build came out of CI rather than a local export/editor run.
const IS_CI_BUILD: bool = ${IS_CI_BUILD}

## Branch whose rolling prerelease this build follows, or "" when it follows
## /releases/latest/ like every normal release.
const RELEASE_BRANCH: String = "${RELEASE_BRANCH}"

## What landed in this build, newest first. Baked in so the app can show its own
## patch notes with no network access.
const CHANGES := ${CHANGES_LITERAL}
EOF

# Android refuses to install an update whose versionCode is lower than the
# installed one, so versionCode tracks content_version -- which moves on every
# release -- rather than binary_version, which only moves when a new APK is
# genuinely required. Any published APK can therefore install over any older one.
#
# Optional: a project with no export presets yet (or no Android target) still
# gets a valid build stamp, which is all the launcher itself needs.
if [[ -f export_presets.cfg ]]; then
	sed -i -E "s|^version/code=.*|version/code=${CONTENT_VERSION}|" export_presets.cfg
	sed -i -E "s|^version/name=.*|version/name=\"${VERSION_NAME}\"|" export_presets.cfg
else
	echo "No export_presets.cfg; skipping the Android version stamp."
fi

# A branch build has to be a different app, not a newer version of the same one.
#
# Android identifies an app by its package id, so without a distinct one the
# branch APK replaces the player's app -- and, signed with the same release key,
# the next release APK replaces it straight back. A distinct id also gives it its
# own private storage, which is what separates user:// on Android.
#
# The names carry a "(branch)" label as well, because two icons with the same
# name on one home screen is its own kind of bug.
if [[ -n "$RELEASE_BRANCH" && -f export_presets.cfg ]]; then
	RELEASE_BRANCH="$RELEASE_BRANCH" BRANCH_PACKAGE_SEGMENT="$BRANCH_PACKAGE_SEGMENT" python3 - <<'PYEOF'
import os, pathlib, re, sys

branch = os.environ["RELEASE_BRANCH"]
segment = os.environ["BRANCH_PACKAGE_SEGMENT"]
label = f" ({branch})"
path = pathlib.Path("export_presets.cfg")
text = path.read_text(encoding="utf-8")


def suffix_package(match: re.Match) -> str:
    current = match.group(1)
    # Idempotent: a rerun in the same workspace must not stack the segment.
    if current.endswith("." + segment):
        return match.group(0)
    return f'package/unique_name="{current}.{segment}"'


def suffix_name(match: re.Match) -> str:
    key, current = match.group(1), match.group(2)
    if current.endswith(label):
        return match.group(0)
    return f'{key}="{current}{label}"'


text, package_edits = re.subn(
    r'^package/unique_name="([^"]*)"$', suffix_package, text, flags=re.M
)
text = re.sub(
    r'^(package/name|application/product_name|application/file_description)="([^"]*)"$',
    suffix_name,
    text,
    flags=re.M,
)
path.write_text(text, encoding="utf-8")

# A preset file with an Android target but no package id would produce a branch
# APK that overwrites the player's app, which is the whole thing this prevents.
if package_edits == 0 and re.search(r'^platform="Android"$', text, flags=re.M):
    sys.exit(
        "export_presets.cfg has an Android preset but no package/unique_name to "
        "give a branch segment; a branch APK would replace the release app."
    )
print(f"Branch identity applied to {package_edits} Android package id(s).")
PYEOF
fi

# Every other platform keeps its user:// where the project name puts it, so a
# branch build would share the release build's save directory -- and with it
# user://update_state.json, which names the content pack to mount. A custom user
# dir is what stops the release app booting the branch's content.
#
# Written into project.godot rather than left to a feature-tag override in the
# committed file, because project.godot is not synced into consuming games: a fix
# made there would never reach a game that already exists, while ci/ is synced
# wholesale, so this reaches all of them.
if [[ -n "$RELEASE_BRANCH" ]]; then
	USER_DIR_NAME="${GAME_SLUG}-${BRANCH_SLUG}" python3 - <<'PYEOF'
import os, pathlib, re, sys

name = os.environ["USER_DIR_NAME"]
path = pathlib.Path("project.godot")
text = path.read_text(encoding="utf-8")

# Keys inside [application] are written section-relative -- config/name, not
# application/config/name -- so they have to be placed in that section.
header = re.search(r"^\[application\][^\n]*$", text, flags=re.M)
if header is None:
    sys.exit(
        "project.godot has no [application] section, so this branch build cannot be "
        "given its own user:// directory. Refusing to ship a build that would share "
        "the release app's saved data."
    )

start, end = header.end(), len(text)
following = re.search(r"^\[", text[start:], flags=re.M)
if following is not None:
    end = start + following.start()
body = text[start:end]


def set_key(section: str, key: str, value: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.M)
    if pattern.search(section):
        return pattern.sub(f"{key}={value}", section, count=1)
    return f"\n{key}={value}" + section


body = set_key(body, "config/use_custom_user_dir", "true")
body = set_key(body, "config/custom_user_dir_name", f'"{name}"')
path.write_text(text[:start] + body + text[end:], encoding="utf-8")
print(f"user:// for this build is the custom dir {name!r}.")
PYEOF
fi

echo "game_name=${GAME_NAME}"
echo "apk_name=${APK_NAME}"
echo "exe_name=${EXE_NAME}"
echo "version_name=${VERSION_NAME}"
echo "binary_version=${BINARY_VERSION}"
echo "content_version=${CONTENT_VERSION}"
echo "commit=${COMMIT}"
echo "built_at=${BUILT_AT}"
echo "release_branch=${RELEASE_BRANCH}"
echo "tag=${TAG}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "game_name=${GAME_NAME}"
		echo "game_slug=${GAME_SLUG}"
		echo "apk_name=${APK_NAME}"
		echo "exe_name=${EXE_NAME}"
		echo "version_name=${VERSION_NAME}"
		echo "binary_version=${BINARY_VERSION}"
		echo "content_version=${CONTENT_VERSION}"
		echo "commit=${COMMIT}"
		echo "built_at=${BUILT_AT}"
		echo "release_branch=${RELEASE_BRANCH}"
		echo "tag=${TAG}"
	} >> "$GITHUB_OUTPUT"
fi
