#!/usr/bin/env bash
# Publishes (or refreshes) the GitHub release that the in-app updater polls.
#
# Asset names are intentionally version-free -- biogenic.apk, Biogenic.exe,
# manifest.json -- because the app fetches them through
# /releases/latest/download/<name>, which only resolves if the name is stable
# from one release to the next.
set -euo pipefail

: "${TAG:?TAG must be set}"
: "${VERSION_NAME:?VERSION_NAME must be set}"
: "${BINARY_VERSION:?BINARY_VERSION must be set}"
: "${CONTENT_VERSION:?CONTENT_VERSION must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RELEASE_DIR="${RELEASE_DIR:-build/release}"
COMMIT_SUBJECT="$(git log -1 --pretty=%s)"
SIGNING_KIND="${SIGNING_KIND:-unknown}"

# Checksums for anyone verifying a manual download. Exclude the file itself so
# reruns stay idempotent.
(
	cd "$RELEASE_DIR"
	find . -maxdepth 1 -type f ! -name 'SHA256SUMS' -printf '%P\n' | sort | xargs sha256sum > SHA256SUMS
)

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT

{
	echo "## Biogenic ${VERSION_NAME}"
	echo ""
	echo "| | |"
	echo "|---|---|"
	echo "| Binary version | \`${BINARY_VERSION}\` |"
	echo "| Content version | \`${CONTENT_VERSION}\` |"
	echo "| Commit | \`$(git rev-parse --short=8 HEAD)\` — ${COMMIT_SUBJECT} |"
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
	echo "- **Android** — [biogenic.apk](https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/biogenic.apk)"
	echo "- **Windows** — [Biogenic.exe](https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/Biogenic.exe) (single self-contained file)"
	echo ""
	echo "Install once and the app updates itself from then on: the main menu checks this"
	echo "release feed on launch, and applies whatever it finds — a new APK on Android, or a"
	echo "content pack plus a restart when the change does not need a new binary."
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
	gh release edit "$TAG" --title "Biogenic ${VERSION_NAME}" --notes-file "$NOTES" --latest
else
	gh release create "$TAG" "$RELEASE_DIR"/* \
		--title "Biogenic ${VERSION_NAME}" \
		--notes-file "$NOTES" \
		--latest
fi

echo "Published ${TAG}: https://github.com/${GITHUB_REPOSITORY}/releases/tag/${TAG}"
