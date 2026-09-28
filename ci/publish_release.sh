#!/usr/bin/env bash
# Publishes (or refreshes) the GitHub release that the in-app updater polls.
#
# Asset names are intentionally version-free -- <game>.apk, <Game>.exe,
# manifest.json -- because the app fetches them through a path that does not
# change from one release to the next: /releases/latest/download/<name> normally,
# or /releases/download/branch-<name>/<asset> for a branch build.
#
# With RELEASE_BRANCH set, TAG is that branch's rolling tag and the release is
# published as a prerelease. GitHub defines the latest release as the newest one
# that is neither a prerelease nor a draft, so /releases/latest/ never returns it
# and no player on the normal update path can ever be offered it. The same tag is
# reused on every push to the branch -- `gh release upload --clobber` refreshes
# the assets in place -- which is what makes the URL the branch build polls fixed
# while its contents roll forward.
set -euo pipefail

: "${TAG:?TAG must be set}"
: "${VERSION_NAME:?VERSION_NAME must be set}"
: "${GAME_NAME:?GAME_NAME must be set}"
: "${APK_NAME:?APK_NAME must be set}"
: "${EXE_NAME:?EXE_NAME must be set}"
: "${BINARY_VERSION:?BINARY_VERSION must be set}"
: "${CONTENT_VERSION:?CONTENT_VERSION must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RELEASE_DIR="${RELEASE_DIR:-build/release}"
COMMIT_SUBJECT="$(git log -1 --pretty=%s)"
SIGNING_KIND="${SIGNING_KIND:-unknown}"
# Empty -- the normal case -- publishes exactly as it always did.
RELEASE_BRANCH="${RELEASE_BRANCH:-}"

if [[ -n "$RELEASE_BRANCH" ]]; then
	RELEASE_TITLE="${GAME_NAME} ${VERSION_NAME} (${RELEASE_BRANCH})"
	# --prerelease is the whole mechanism, and it is not paired with an explicit
	# --latest=false: a prerelease cannot be the latest release by GitHub's own
	# definition, so one flag cannot contradict the other.
	RELEASE_FLAGS=(--prerelease)
	# Not /releases/latest/download/: that path is exactly what this release is
	# kept out of, so a link through it would hand out the players' build instead.
	DOWNLOAD_BASE="https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}"
else
	RELEASE_TITLE="${GAME_NAME} ${VERSION_NAME}"
	RELEASE_FLAGS=(--latest)
	DOWNLOAD_BASE="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download"
fi

# Checksums for anyone verifying a manual download. Exclude the file itself so
# reruns stay idempotent.
(
	cd "$RELEASE_DIR"
	find . -maxdepth 1 -type f ! -name 'SHA256SUMS' -printf '%P\n' | sort | xargs sha256sum > SHA256SUMS
)

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT

{
	echo "## ${RELEASE_TITLE}"
	echo ""
	if [[ -n "$RELEASE_BRANCH" ]]; then
		echo "> **Branch build — not a release.** This is the rolling prerelease for"
		echo "> \`${RELEASE_BRANCH}\`, refreshed on every push to that branch. It is a"
		echo "> separate app: its own Android package id, its own name, and its own saved"
		echo "> data, so it installs beside the released app rather than replacing it."
		echo "> Only a build exported for \`${RELEASE_BRANCH}\` polls this tag; nothing built"
		echo "> from the default branch can reach it."
		echo ""
	fi
	echo "| | |"
	echo "|---|---|"
	echo "| Binary version | \`${BINARY_VERSION}\` |"
	echo "| Content version | \`${CONTENT_VERSION}\` |"
	echo "| Commit | \`$(git rev-parse --short=8 HEAD)\` — ${COMMIT_SUBJECT} |"
	if [[ -n "$RELEASE_BRANCH" ]]; then
		echo "| Branch | \`${RELEASE_BRANCH}\` |"
	fi
	echo ""
	if [[ -s "build/notes/changes.json" ]]; then
		echo "### What's new"
		echo ""
		python3 -c "
import json, sys
with open('build/notes/changes.json', encoding='utf-8') as fh:
    for line in json.load(fh):
        print(f'- {line}')
" || true
		echo ""
	fi
	echo "### Download"
	echo ""
	echo "- **Android** — [${APK_NAME}](${DOWNLOAD_BASE}/${APK_NAME})"
	echo "- **Windows** — [${EXE_NAME}](${DOWNLOAD_BASE}/${EXE_NAME}) (single self-contained file)"
	echo ""
	if [[ -n "$RELEASE_BRANCH" ]]; then
		echo "Install once and this build updates itself from this tag on every launch, so"
		echo "each push to \`${RELEASE_BRANCH}\` reaches the device without another manual"
		echo "install — including a binary update, which is the part only a real device can"
		echo "prove works."
	else
		echo "Install once and the app updates itself from then on: the main menu checks this"
		echo "release feed on launch, and applies whatever it finds — a new APK on Android, or a"
		echo "content pack plus a restart when the change does not need a new binary."
	fi
	echo ""
	if [[ "$SIGNING_KIND" != "release" ]]; then
		echo "> ⚠️ This APK is signed with a CI debug key, not a release keystore."
		echo "> See [docs/UPDATES.md](https://github.com/${GITHUB_REPOSITORY}/blob/main/docs/UPDATES.md#signing)."
		echo ""
	fi
	echo "<sub>\`manifest.json\` is what the updater reads. \`SHA256SUMS\` covers every asset here.</sub>"
} > "$NOTES"

if gh release view "$TAG" >/dev/null 2>&1; then
	echo "Release ${TAG} exists — refreshing its assets."
	gh release upload "$TAG" "$RELEASE_DIR"/* --clobber
	gh release edit "$TAG" --title "$RELEASE_TITLE" --notes-file "$NOTES" "${RELEASE_FLAGS[@]}"
else
	gh release create "$TAG" "$RELEASE_DIR"/* \
		--title "$RELEASE_TITLE" \
		--notes-file "$NOTES" \
		"${RELEASE_FLAGS[@]}"
fi

echo "Published ${TAG}: https://github.com/${GITHUB_REPOSITORY}/releases/tag/${TAG}"
