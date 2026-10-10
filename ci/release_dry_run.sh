#!/usr/bin/env bash
# Rehearses the tail of release.yml on a pull request: assemble the release
# directory, build the manifest, and run publish_release.sh -- everything between
# "the exports exist" and "the release is on GitHub" -- against a stand-in for gh,
# so nothing is published and no token is involved.
#
# Until this existed, nothing in CI ran any of it. A broken artifact name, a
# manifest the app could not read, or a publish script that failed on a path it had
# never been run on showed up for the first time on a merge to main, with players
# already pointed at that release feed.
#
# It does not carry its own copy of those steps. It pulls the "Assemble release
# directory" and "Build update manifest" run blocks out of release.yml and executes
# them, so the rehearsal cannot drift from the workflow, and a game that changes its
# release.yml (another platform, another artifact) is rehearsed as it actually is.
# Expressions of the form steps.version.outputs.NAME become the environment
# variable NAME; any other expression, or a step that cannot be found, is an error.
#
# Then it checks what the in-app updater and a person downloading by hand rely on:
#   * manifest.json names at least the artifacts the template's updater looks up
#     (Android and Windows binaries; Android, Windows, Linux and macOS content
#     packs), and every entry it lists matches the file that would be uploaded: name,
#     SHA-256, size, and a URL pinned to this release's tag;
#   * publish_release.sh asks for a release carrying every file in the release
#     directory, as the latest release (or as a prerelease for a branch build), and
#     its notes link the APK and the executable.
#
# What it cannot tell is whether GitHub accepts the upload. The release workflow
# stays the only thing that publishes.
#
# Limits, for a game built from the template: the steps are found by name and the release
# directory must be build/release; each runs under bash -euo pipefail (GitHub gives bash -e)
# with the steps.version.outputs values as environment variables; a step's own env:,
# working-directory:, shell: and if: are ignored; "run: >" blocks and expressions other than
# steps.version.outputs.* are refused with an error. A game that needs more than that should
# drop the rehearsal step from its own ci.yml; ci/ is overwritten by the sync.
#
# Reads the values the workflow's steps read: TAG, VERSION_NAME, GAME_NAME,
# APK_NAME, EXE_NAME, BINARY_VERSION, CONTENT_VERSION, COMMIT, GITHUB_REPOSITORY,
# and optionally RELEASE_BRANCH and SIGNING_KIND, all in the environment: the extracted
# steps run in a child shell.
set -euo pipefail

: "${TAG:?TAG must be set}"
: "${VERSION_NAME:?VERSION_NAME must be set}"
: "${GAME_NAME:?GAME_NAME must be set}"
: "${APK_NAME:?APK_NAME must be set}"
: "${EXE_NAME:?EXE_NAME must be set}"
: "${BINARY_VERSION:?BINARY_VERSION must be set}"
: "${CONTENT_VERSION:?CONTENT_VERSION must be set}"
: "${COMMIT:?COMMIT must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORKFLOW=".github/workflows/release.yml"
RELEASE_DIR="build/release"

# Prints the shell of one workflow step's "run: |" block, with
# steps.version.outputs.NAME replaced by the variable NAME.
extract_step() {
	WORKFLOW="$WORKFLOW" python3 - "$1" <<'PY'
import os
import re
import sys
import textwrap

name = sys.argv[1]
path = os.environ["WORKFLOW"]
try:
    text = open(path, encoding="utf-8").read()
except OSError as error:
    sys.exit("::error::cannot read %s: %s" % (path, error))

# Any "      - " opens the next step, named or not, so a step without a run block cannot
# lend the one after it. A step name may be quoted.
heading = re.compile(
    r"^      - name: [\"']?" + re.escape(name) + r"[\"']?[ \t]*(?:#[^\n]*)?\n(.*?)(?=^      - |\Z)",
    re.S | re.M,
)
found = list(heading.finditer(text))
if not found:
    sys.exit("::error::%s has no step named %r; the release rehearsal needs it." % (path, name))
if len(found) > 1:
    sys.exit("::error::%s has %d steps named %r; the release rehearsal cannot tell which one runs."
             % (path, len(found), name))

# The run block is every following line indented deeper than the key. A line of only
# whitespace belongs to it whatever its width, because YAML reads it as an empty line:
# stopping there would run half a block and report success. A last line with no newline
# is still a line.
step_text = found[0].group(1)
if not step_text.endswith("\n"):
    step_text += "\n"
run = re.search(r"^        run: \|[-+]?[ \t]*(?:#.*)?\n((?:          .*\n|[ \t]*\n)+)", step_text, re.M)
if run is None:
    sys.exit("::error::step %r in %s has no 'run: |' block." % (name, path))

body = textwrap.dedent(run.group(1))
body = re.sub(r"\$\{\{ steps\.version\.outputs\.(\w+) \}\}", lambda m: "$" + "{" + m.group(1).upper() + "}", body)
if "$" + "{{" in body:
    sys.exit("::error::step %r uses an expression the rehearsal cannot resolve: %s"
             % (name, re.search(r"\$\{\{[^}]*\}\}", body).group(0)))
sys.stdout.write(body)
PY
}

# -u on purpose, and stricter than the shell GitHub gives a run step: a workflow output
# that ci.yml does not pass would otherwise expand to nothing and the rehearsal would
# pass on a manifest built from empty values.
run_release_step() {
	local script
	script="$(extract_step "$1")"
	echo "--- release.yml step: $1 ---"
	bash -euo pipefail -c "$script"
}

# A stray directory from an earlier run must not leak into what is "uploaded".
rm -rf "$RELEASE_DIR"

run_release_step "Assemble release directory"

if [[ ! -d "$RELEASE_DIR" ]]; then
	echo "::error::the assemble step did not create $RELEASE_DIR." >&2
	exit 1
fi
empty="$(find "$RELEASE_DIR" -type f -empty)"
if [[ -n "$empty" ]]; then
	echo "::error::these assets would be published empty: $empty" >&2
	exit 1
fi

run_release_step "Build update manifest"

RELEASE_DIR="$RELEASE_DIR" python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import urllib.parse

release = pathlib.Path(os.environ["RELEASE_DIR"])
tag = os.environ["TAG"]
repo = os.environ["GITHUB_REPOSITORY"]
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
problems = []


def check(ok, message):
    if not ok:
        problems.append(message)


check(manifest.get("release_tag") == tag, "release_tag is %r, expected %r" % (manifest.get("release_tag"), tag))
check(manifest.get("binary_version") == int(os.environ["BINARY_VERSION"]), "binary_version does not match the stamp")
check(manifest.get("content_version") == int(os.environ["CONTENT_VERSION"]), "content_version does not match the stamp")
check(manifest.get("version_name") == os.environ["VERSION_NAME"], "version_name does not match the stamp")

# What the template's updater looks up. A game may publish more; it may not publish less.
required = {
    ("binary", "android"): os.environ["APK_NAME"],
    ("binary", "windows"): os.environ["EXE_NAME"],
    ("content", "android"): None,
    ("content", "windows"): None,
    ("content", "linux"): None,
    ("content", "macos"): None,
}
artifacts = manifest.get("artifacts", {})
for (kind, platform), name in required.items():
    entry = artifacts.get(kind, {}).get(platform)
    if entry is None:
        problems.append("%s:%s is missing from the manifest" % (kind, platform))
    elif name is not None and entry.get("file") != name:
        problems.append("%s:%s names file %r, expected %r" % (kind, platform, entry.get("file"), name))

listed = 0
for kind, platforms in artifacts.items():
    for platform, entry in platforms.items():
        label = "%s:%s" % (kind, platform)
        name = entry.get("file", "")
        path = release / name
        if not name or not path.is_file():
            problems.append("%s names %r, which is not in the release directory" % (label, name))
            continue
        listed += 1
        data = path.read_bytes()
        check(entry.get("sha256") == hashlib.sha256(data).hexdigest(), "%s sha256 does not match %s" % (label, name))
        check(entry.get("size") == len(data), "%s size does not match %s" % (label, name))
        url = "https://github.com/%s/releases/download/%s/%s" % (repo, urllib.parse.quote(tag, safe=""), name)
        check(entry.get("url") == url, "%s url is %r, expected %r" % (label, entry.get("url"), url))

changelog = manifest.get("changelog")
check(isinstance(changelog, list) and changelog, "changelog is empty")
if isinstance(changelog, list) and changelog:
    check(changelog[0].get("content_version") == int(os.environ["CONTENT_VERSION"]), "the newest changelog entry is not this build")

if problems:
    for problem in problems:
        print("::error::manifest check: " + problem, file=sys.stderr)
    sys.exit(1)
print("manifest.json is consistent with the %d artifact entries it lists." % listed)
PY

# publish_release.sh against a gh that only writes down what it was asked.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$DRY_RUN_GH_LOG"
prev=""
for arg in "$@"; do
	if [[ "$prev" == --notes-file ]]; then
		cp "$arg" "$DRY_RUN_GH_NOTES"
	fi
	prev="$arg"
done
# "release view" fails: this tag does not exist yet, so the create path runs.
[[ "$1 $2" == "release view" ]] && exit 1
exit 0
STUBEOF
chmod +x "$STUB/gh"

# Its own output ends with "Published ...", which would read as true in a CI log,
# so every line is marked as coming from the rehearsal. pipefail keeps its exit code.
echo "--- publish_release.sh, with a stand-in for gh: nothing below was published ---"
DRY_RUN_GH_LOG="$STUB/calls.log" DRY_RUN_GH_NOTES="$STUB/notes.md" \
	PATH="$STUB:$PATH" RELEASE_DIR="$RELEASE_DIR" \
	bash ci/publish_release.sh 2>&1 | sed 's/^/    | /'
echo "--- end of publish_release.sh output ---"

STUB="$STUB" RELEASE_DIR="$RELEASE_DIR" python3 - <<'PY'
import os
import pathlib
import sys

stub = pathlib.Path(os.environ["STUB"])
release = pathlib.Path(os.environ["RELEASE_DIR"])
tag = os.environ["TAG"]
branch = os.environ.get("RELEASE_BRANCH", "")
calls = (stub / "calls.log").read_text(encoding="utf-8").splitlines()
notes = (stub / "notes.md").read_text(encoding="utf-8")
problems = []

assets = sorted(p.name for p in release.iterdir() if p.is_file())
create = [c for c in calls if c.startswith("release create ")]
if len(create) != 1:
    problems.append("expected one 'gh release create', got %d: %s" % (len(create), calls))
else:
    call = create[0]
    if not call.startswith("release create %s " % tag):
        problems.append("release create is not for the tag %s: %s" % (tag, call))
    if "--draft" in call:
        problems.append("a release must not be created as a draft, players cannot see one: %s" % call)
    for name in assets:
        if "%s/%s" % (os.environ["RELEASE_DIR"], name) not in call:
            problems.append("%s is not among the uploaded assets" % name)
    for required in ("manifest.json", "SHA256SUMS", os.environ["APK_NAME"], os.environ["EXE_NAME"]):
        if required not in assets:
            problems.append("%s is not in the release directory" % required)
    if branch:
        if "--prerelease" not in call or "--latest" in call:
            problems.append("a branch build must be a prerelease and never latest: %s" % call)
    elif "--latest" not in call or "--prerelease" in call:
        problems.append("a release must be created as latest: %s" % call)

base = ("https://github.com/%s/releases/download/%s" % (os.environ["GITHUB_REPOSITORY"], tag)
        if branch else "https://github.com/%s/releases/latest/download" % os.environ["GITHUB_REPOSITORY"])
for name in (os.environ["APK_NAME"], os.environ["EXE_NAME"]):
    if "(%s/%s)" % (base, name) not in notes:
        problems.append("the release notes do not link %s through %s" % (name, base))

if problems:
    for problem in problems:
        print("::error::publish check: " + problem, file=sys.stderr)
    sys.exit(1)
print("publish_release.sh asked for a %s release with %d assets." % ("prerelease" if branch else "latest", len(assets)))
PY

echo "Release rehearsal passed for ${TAG}: nothing was published."
