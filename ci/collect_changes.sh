#!/usr/bin/env bash
# Collects the patch notes for this release.
#
# Writes two files that make_manifest.py folds into the manifest:
#   build/notes/changes.json    - this release's changes, as a JSON string array
#   build/notes/previous.json   - the previous release's manifest, if there is
#                                 one, so its changelog can be carried forward
#
# Carrying the history forward matters: a player who is several releases behind
# should see everything that happened since their build, not only the newest
# entry.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="build/notes"
mkdir -p "$OUT_DIR"

# Release tags are "v<name>+<content_version>", and content_version is the commit
# count, so sorting numerically on the suffix gives the true previous release.
# The current release's tag does not exist yet -- it is created at publish time.
PREV_TAG="$(git tag --list 'v*+*' \
	| awk -F'+' 'NF==2 && $2 ~ /^[0-9]+$/ {print $2"\t"$0}' \
	| sort -n -k1,1 \
	| tail -1 \
	| cut -f2-)"

if [[ -n "$PREV_TAG" ]]; then
	echo "Previous release: ${PREV_TAG}"
	RANGE="${PREV_TAG}..HEAD"
else
	echo "No previous release found; describing the whole history."
	RANGE="HEAD"
fi

# Subject lines only, newest first, merges dropped.
git log --no-merges --pretty=format:%s "$RANGE" > "$OUT_DIR/changes.txt" || true

python3 - "$OUT_DIR/changes.txt" "$OUT_DIR/changes.json" <<'PY'
import json, sys

src, dest = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as fh:
    lines = [line.strip() for line in fh if line.strip()]

# Drop the housekeeping commits nobody wants in a player-facing patch note.
NOISE = ("bump ", "chore", "ci:", "wip", "merge ", "revert ")
changes = [l for l in lines if not l.lower().startswith(NOISE)]

with open(dest, "w", encoding="utf-8") as fh:
    json.dump(changes, fh, indent=2)
print(f"{len(changes)} change(s) collected")
PY

# Pull the previous manifest so its changelog can be carried forward. Absent on
# the very first release, and a failure here must not break the build.
if [[ -n "$PREV_TAG" ]] && [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
	if gh release download "$PREV_TAG" --pattern manifest.json --output "$OUT_DIR/previous.json" --clobber 2>/dev/null; then
		echo "Carried forward the changelog from ${PREV_TAG}."
	else
		echo "No previous manifest to carry forward."
	fi
fi
