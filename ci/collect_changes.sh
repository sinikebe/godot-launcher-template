#!/usr/bin/env bash
# Collects the patch notes for this release.
#
# Writes two files that make_manifest.py folds into the manifest:
#   build/notes/changes.json    - this release's changes, as a JSON string array
#   build/notes/previous.json   - the latest release's manifest, if there is
#                                 one, so its changelog can be carried forward
#
# Carrying the history forward matters: a player who is several releases behind
# should see everything that happened since their build, not only the newest
# entry.
#
# The notes start where the latest release was built: the "commit" its manifest
# records. That works the same whether releases are published to this repository
# or, with RELEASE_REPO, to a separate public one that holds only releases and
# shares none of this history. Without a token, or without a usable manifest, it
# falls back to the newest "v<name>+<n>" tag in this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="build/notes"
mkdir -p "$OUT_DIR"
# A manifest left by an earlier run must not be carried forward as this one's.
rm -f "$OUT_DIR/previous.json"

# Where releases are published. gh reads GH_REPO, so every gh call below asks
# that repository; unset, gh uses this checkout's own.
RELEASE_REPO="${RELEASE_REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -n "$RELEASE_REPO" ]]; then
	export GH_REPO="$RELEASE_REPO"
fi

# Pull the latest release's manifest. Absent on the very first release, and a
# failure here must not break the build.
PREV_COMMIT=""
if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
	FROM_REPO="$RELEASE_REPO"
	# A releases repository with no release yet is a game moving to one: its
	# releases so far are in this repository, and so is the history its players
	# have. Only when GitHub says there is none -- a 404 for the latest release,
	# which drafts and prereleases never are. Any other error is not "none".
	# `gh api`, which every gh has, rather than `gh release list --json`, which
	# gh before 2.43 rejects.
	if [[ -n "${GITHUB_REPOSITORY:-}" && "${RELEASE_REPO,,}" != "${GITHUB_REPOSITORY,,}" ]]; then
		if LATEST_ERR="$(gh api "repos/${RELEASE_REPO}/releases/latest" --silent 2>&1)"; then
			:
		elif [[ "$LATEST_ERR" == *"(HTTP 404)"* ]]; then
			echo "${RELEASE_REPO} has no release yet; starting from the latest release in ${GITHUB_REPOSITORY}."
			FROM_REPO="$GITHUB_REPOSITORY"
			export GH_REPO="$FROM_REPO"
		else
			echo "::warning::Could not tell whether ${RELEASE_REPO} has a release yet, so the notes start from its latest release, if any: ${LATEST_ERR}"
		fi
	fi
	if gh release download --pattern manifest.json --output "$OUT_DIR/previous.json" --clobber 2>/dev/null; then
		echo "Carried forward the changelog of the latest release${FROM_REPO:+ in ${FROM_REPO}}."
		# Checked as hex before git sees it: the manifest is downloaded, and a value
		# starting with "-" would otherwise reach git as an option.
		PREV_COMMIT="$(python3 - "$OUT_DIR/previous.json" <<'PY'
import json, re, sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        commit = json.load(fh).get("commit", "")
except (ValueError, OSError, AttributeError):
    commit = ""
if isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{7,40}", commit):
    print(commit)
PY
)"
	else
		rm -f "$OUT_DIR/previous.json"
		echo "No previous manifest to carry forward."
	fi
fi

RANGE=""
RERUN=false
if [[ -n "$PREV_COMMIT" ]]; then
	if PREV_FULL="$(git rev-parse --verify --quiet "${PREV_COMMIT}^{commit}")"; then
		if [[ "$PREV_FULL" == "$(git rev-parse HEAD)" ]]; then
			# The latest release was built from this very commit: this is a re-run, and
			# the range since it is empty. Describe what that release described.
			echo "The latest release was built from this commit; reusing its notes."
			RERUN=true
		else
			echo "Previous release: commit ${PREV_COMMIT}"
			RANGE="${PREV_COMMIT}..HEAD"
		fi
	else
		echo "The latest release was built from ${PREV_COMMIT}, which is not in this history; falling back to release tags."
	fi
fi

if [[ "$RERUN" == false && -z "$RANGE" ]]; then
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
fi

: > "$OUT_DIR/changes.txt"
if [[ "$RERUN" == false ]]; then
	# Subject lines only, newest first, merges dropped.
	git log --no-merges --pretty=format:%s "$RANGE" > "$OUT_DIR/changes.txt" || true
fi

python3 - "$OUT_DIR/changes.txt" "$OUT_DIR/changes.json" "$RERUN" "$OUT_DIR/previous.json" <<'PY'
import json, sys

src, dest, rerun, previous = sys.argv[1], sys.argv[2], sys.argv[3] == "true", sys.argv[4]

# The one cap on a release's notes. The manifest, the notes baked into the build and
# the GitHub release body all read this file, so they all show the same lines. The
# manifest is fetched on every launch, and a first release on top of a long history
# would otherwise list every commit it has ever had.
MAX_LINES = 20

if rerun:
    changes = []
    try:
        with open(previous, encoding="utf-8") as fh:
            entry = json.load(fh)["changelog"][0]
        if isinstance(entry["changes"], list):
            changes = [str(c) for c in entry["changes"]]
    except (ValueError, OSError, KeyError, IndexError, TypeError):
        pass
else:
    with open(src, encoding="utf-8") as fh:
        lines = [line.strip() for line in fh if line.strip()]
    # Drop the housekeeping commits nobody wants in a player-facing patch note.
    NOISE = ("bump ", "chore", "ci:", "wip", "merge ", "revert ")
    changes = [l for l in lines if not l.lower().startswith(NOISE)]

if len(changes) > MAX_LINES:
    # Newest first, so the oldest are the ones left out -- and the reader is told.
    # Always two or more: one line over the cap is still two lines left out.
    more = len(changes) - (MAX_LINES - 1)
    changes = changes[: MAX_LINES - 1] + ["…and %d more changes." % more]

with open(dest, "w", encoding="utf-8") as fh:
    json.dump(changes, fh, indent=2)
print(f"{len(changes)} change(s) collected")
PY
