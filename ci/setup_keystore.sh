#!/usr/bin/env bash
# Materialises the Android signing key for this build.
#
# SECURITY NOTES -- this script deliberately:
#   * never echoes a secret, and never puts one on a command line (which would
#     be visible in process listings) or into $GITHUB_ENV (which is not masked);
#   * writes the keystore under $RUNNER_TEMP, OUTSIDE the workspace, so no
#     release/artifact glob can ever sweep it up;
#   * leaves the passwords to be injected straight from the `secrets` context
#     into the export step's env, where Actions masks them automatically.
# It only ever prints the PATH of the keystore, which is not sensitive.
set -euo pipefail

KEYSTORE_DIR="${RUNNER_TEMP:-/tmp}/launcher-signing"
mkdir -p "$KEYSTORE_DIR"
chmod 700 "$KEYSTORE_DIR"
KEYSTORE_PATH="${KEYSTORE_DIR}/android.keystore"

emit() {
	echo "$1"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		echo "$1" >> "$GITHUB_OUTPUT"
	fi
}

if [[ -n "${ANDROID_KEYSTORE_BASE64:-}" ]]; then
	# Fed through stdin rather than an argument so it never reaches the process table.
	printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$KEYSTORE_PATH"
	chmod 600 "$KEYSTORE_PATH"
	if [[ ! -s "$KEYSTORE_PATH" ]]; then
		echo "::error::ANDROID_KEYSTORE_BASE64 did not decode to a usable keystore." >&2
		exit 1
	fi
	emit "kind=release"
	emit "path=${KEYSTORE_PATH}"
	echo "Signing with the release keystore from repository secrets."
	exit 0
fi

# ---------------------------------------------------------------------------
# Fallback: a throwaway debug key, so the pipeline still produces an installable
# APK before anyone has configured signing secrets.
#
# It is restored from the Actions cache under a fixed key so the SIGNATURE STAYS
# THE SAME between runs. That matters: Android refuses to update an installed
# app whose new APK is signed with a different key, so a freshly generated key
# on every run would break in-place self-update entirely.
# ---------------------------------------------------------------------------
CACHE_DIR="${KEYSTORE_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/launcher-keystore-cache}"
mkdir -p "$CACHE_DIR"
CACHED="${CACHE_DIR}/debug.keystore"

if [[ -s "$CACHED" ]]; then
	echo "Reusing the cached debug keystore (signature stays stable)."
else
	echo "Generating a debug keystore (no ANDROID_KEYSTORE_BASE64 secret is set)."
	keytool -genkeypair \
		-keystore "$CACHED" \
		-storepass android \
		-keypass android \
		-alias androiddebugkey \
		-keyalg RSA \
		-keysize 2048 \
		-validity 10950 \
		-dname "CN=${GAME_NAME:-Game} Debug, OU=CI, O=${GAME_NAME:-Game}, L=, S=, C=US" \
		-noprompt
fi

cp "$CACHED" "$KEYSTORE_PATH"
chmod 600 "$KEYSTORE_PATH"
emit "kind=debug"
emit "path=${KEYSTORE_PATH}"

{
	echo "### ⚠️ Signed with a throwaway debug key"
	echo ""
	echo "No \`ANDROID_KEYSTORE_BASE64\` secret is configured, so this APK was signed"
	echo "with a CI-generated debug key kept alive by the Actions cache."
	echo ""
	echo "Actions caches are evicted after 7 days without a hit. If that happens a new"
	echo "key is generated, and Android will then refuse to update any already-installed"
	echo "copy in place — testers would have to uninstall first."
	echo ""
	echo "See \`docs/UPDATES.md\` for how to create a real keystore and add it as a secret."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
