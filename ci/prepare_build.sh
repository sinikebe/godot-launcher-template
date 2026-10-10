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

# The version name is written into build_version.gd, into export_presets.cfg through
# sed, into the release tag "v<name>+<n>", and release.yml passes it to a shell script.
# So it has to be a plain token, checked here before any file is touched: an "&" in the
# sed replacement is the text matched (it silently wrote a second version/name= into the
# preset file), a "|" ends the expression halfway through the run, and a quote or a
# backslash breaks the GDScript constant. A tag cannot hold a space, ".." or most of the
# rest either, so a name refused here would also have failed at "gh release create".
# "+" is refused too although a tag could hold it: it is the separator in "v<name>+<n>",
# and collect_changes.sh finds the previous release by splitting tags on it, so a name
# with a "+" made it see no previous release and describe the whole history.
if [[ ! "$VERSION_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [[ "$VERSION_NAME" == *..* ]]; then
	echo "::error::version_name in version.json is not usable: it has to start with a letter or digit and use only letters, digits, dot, underscore and hyphen, with no \"..\"." >&2
	echo "It becomes part of the release tag and is written into build_version.gd and export_presets.cfg, so a space, a quote, \"&\", \"|\" or a backslash would corrupt them." >&2
	exit 1
fi

# Commit count is monotonic on main and moves on every merge, which is exactly
# the property a content version needs.
CONTENT_VERSION="$(git rev-list --count HEAD)"
COMMIT="$(git rev-parse --short=8 HEAD)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Empty -- the normal case -- builds exactly what it always did: a release that
# /releases/latest/ serves to every player.
RELEASE_BRANCH="${RELEASE_BRANCH:-}"

if [[ -n "$RELEASE_BRANCH" ]]; then
	# Mirrors LauncherConfig.branch_is_valid(). The name is used verbatim as
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
			"app polls, and LauncherConfig.branch_is_valid() applies the same rule -- so a" \
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
            data = json.load(fh)
        # null, a number or a string is valid JSON and not a list of notes. A string
        # would otherwise be split into characters and a number would raise.
        items = [str(x) for x in data][:20] if isinstance(data, list) else []
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
import os, pathlib, re, subprocess, sys

branch = os.environ["RELEASE_BRANCH"]
segment = os.environ["BRANCH_PACKAGE_SEGMENT"]
label = f" ({branch})"
path = pathlib.Path("export_presets.cfg")
text = path.read_text(encoding="utf-8")

# The suffix is applied to the value this file carries in the commit being built,
# not to whatever the working copy currently holds. "Does it already end in
# .<segment>?" was a guess, and it guessed wrong in the one case that matters: a
# game whose own package id happens to end in .dev kept the release build's exact
# id, so the branch APK would have replaced the player's app -- and the script
# said it had applied the identity. Reading the committed value is exact, and a
# rerun in the same workspace lands on the same answer.
def committed_text(name: str) -> str:
    try:
        return subprocess.run(
            ["git", "show", f"HEAD:{name}"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, OSError):
        # Not committed yet: fall back to the working copy, which is right on a
        # first run and is all a brand-new project can offer.
        return text


def parse_options(body: str) -> dict[str, str]:
    return dict(re.findall(r'^([A-Za-z0-9_/]+)="([^"]*)"$', body, flags=re.M))


def set_key(body: str, key: str, value: str) -> tuple[str, int]:
    return re.subn(rf'^{re.escape(key)}=.*$', lambda _m: f'{key}="{value}"', body, flags=re.M)


# Each export preset has its own [preset.N.options] section, and its own package id: a
# game can have an APK preset and an AAB preset, or a demo and a full edition. Reading the
# whole file into one dictionary let the last preset's value overwrite every other's, and
# then wrote that one value into all of them.
# A section ends at the next preset header, not at any line that starts with "[": a value
# can span lines, and a line inside it that begins with "[" would otherwise cut the section
# short and silently skip the keys after it.
OPTIONS = re.compile(r"^(\[preset\.(\d+)\.options\][^\n]*\n)(.*?)(?=^\[preset\.\d+(?:\.options)?\]|\Z)", re.M | re.S)
PRESET = re.compile(r"^\[preset\.(\d+)\][^\n]*\n(.*?)(?=^\[preset\.\d+(?:\.options)?\]|\Z)", re.M | re.S)

committed_options = {number: body for _header, number, body in OPTIONS.findall(committed_text("export_presets.cfg"))}
android = {number for number, body in PRESET.findall(text) if re.search(r'^platform="Android"$', body, flags=re.M)}
edited: set[str] = set()


def brand(match: re.Match) -> str:
    number, body = match.group(2), match.group(3)
    base = parse_options(committed_options.get(number, body))
    if "package/unique_name" in base:
        body, count = set_key(body, "package/unique_name", f'{base["package/unique_name"]}.{segment}')
        if count:
            edited.add(number)
    for key in ("package/name", "application/product_name", "application/file_description"):
        if key in base:
            body, _ = set_key(body, key, f"{base[key]}{label}")
    return match.group(1) + body


text = OPTIONS.sub(brand, text)
package_edits = len(edited)

# Checked before the file is written: an aborted run must not leave a tracked file
# half-rewritten for a developer to commit by accident. Every Android preset needs an id
# of its own to extend, because the one without would build an APK that replaces the
# release app.
missing = sorted(android - edited, key=int)
if missing or (not android and re.search(r'^platform="Android"$', text, flags=re.M)):
    names = ", ".join(f"preset.{n}" for n in missing) or "an Android preset"
    sys.exit(
        f"export_presets.cfg: {names} has no package/unique_name to give a branch "
        "segment; a branch APK would replace the release app."
    )

path.write_text(text, encoding="utf-8")
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
#
# Every section header is collected and exactly one must be [application]. A plain
# search for the header took the first line that looked like one anywhere in the
# file, including inside a multi-line string value, and then wrote the keys into
# that string -- destroying the real section, exiting 0, and shipping a branch
# build that shared the release app's user:// after all.
headers = [
    m for m in re.finditer(r"^\[([^\]\n]*)\][^\n]*$", text, flags=re.M)
    if m.group(1) == "application"
]
if len(headers) != 1:
    sys.exit(
        f"project.godot has {len(headers)} [application] section headers; expected "
        "exactly one. Refusing to guess, because getting this wrong ships a branch "
        "build that shares the release app's saved data."
    )
header = headers[0]

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
