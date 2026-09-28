#!/usr/bin/env bash
# Installs the pinned Godot editor and its export templates for headless export,
# and verifies every byte of both before anything is exported with them.
#
# Both land in the exact locations Godot looks in, so every later command is a
# plain `godot ...` with no extra flags.
#
# The verification lives here rather than in a workflow step because
# .github/workflows/ is not synced into consuming games -- a token scoped to
# `contents` cannot write it -- so a check added there would never reach a game
# that already exists. ci/ is synced wholesale, so this does.
#
# What it proves, and what it does not:
#
#   On a download, each archive is checked against the SHA512-SUMS.txt that
#   Godot publishes with the same release. That proves the transfer, not the
#   origin: the sums come from the same place as the bytes.
#
#   On a cache hit, the installed files are checked against a manifest written
#   at install time, when the archives had just been verified -- every file's
#   contents, and the exact set of files. That catches a partial or corrupted
#   restore and anything added to the tree afterwards. It does not prove origin
#   either: a wholly fabricated cache entry could carry a manifest that agrees
#   with itself. Closing that needs a manifest pinned outside the cache, and it
#   cannot live in ci/ -- ci/ is replaced wholesale by the downstream sync, so a
#   manifest for the template's Godot version would be wrong for a game pinning
#   another, and the next sync would revert the correction. A game that wants
#   origin proof pins that manifest in its own repository.
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:?GODOT_VERSION must be set, e.g. 4.7}"
GODOT_RELEASE="${GODOT_RELEASE:-stable}"
FULL="${GODOT_VERSION}-${GODOT_RELEASE}"

BASE="https://github.com/godotengine/godot/releases/download/${FULL}"
INSTALL_DIR="${HOME}/godot"
# Godot resolves templates by "<version>.<status>" and will not look anywhere else.
TEMPLATE_DIR="${HOME}/.local/share/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE}"

EDITOR_ARCHIVE="Godot_v${FULL}_linux.x86_64.zip"
TEMPLATE_ARCHIVE="Godot_v${FULL}_export_templates.tpz"
# Lives inside the tree it describes, because the tree is what the cache
# restores: a manifest kept anywhere else would simply be absent on a hit.
MANIFEST=".verified-install.sha512"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SUMS="${WORK}/SHA512-SUMS.txt"

die() {
	echo "::error::$1"
	shift || true
	# An `if`, not `(( … )) && printf`: as an AND-list the arithmetic failing on a
	# single-argument call would trip `set -e` and skip the exit below.
	if (( $# > 0 )); then
		printf '%s\n' "$@" >&2
	fi
	exit 1
}

# ---------------------------------------------------------------------------
# What the release says the bytes should be
# ---------------------------------------------------------------------------

fetch_sums() {
	[[ -s "$SUMS" ]] && return 0
	curl -fsSL --retry 3 -o "$SUMS" "${BASE}/SHA512-SUMS.txt" || die \
		"Could not fetch SHA512-SUMS.txt for Godot ${FULL}." \
		"" \
		"Nothing can be verified without it, and an unverified engine is not worth" \
		"the release it would sign. Godot publishes this file with every stable" \
		"release -- check that GODOT_VERSION=${GODOT_VERSION} and" \
		"GODOT_RELEASE=${GODOT_RELEASE} name one that exists."
}

# The published sum for one archive, or nothing.
#
# grep -F against the two-space separator, not `grep " $name\$"`: the separator
# in a GNU text-mode sums file is two spaces, and a name like
# Godot_v4.7-stable_linux.x86_64.zip is a regex whose dots match any character --
# measured matching a different, nonexistent archive. Exactly one line must
# match, so a name that is a suffix of another cannot be mistaken for it.
published_sum() {
	local matched
	matched="$(grep -F "  ${1}" "$SUMS" || true)"
	[[ "$(printf '%s' "$matched" | grep -c . || true)" == "1" ]] || return 0
	printf '%s' "${matched%% *}"
}

sha512_of() { sha512sum "$1" | cut -d' ' -f1; }

# Downloads an archive under its published name and does not return until the
# bytes match. Progress goes to stderr: stdout is the path.
#
# Not `grep ... | sha512sum -c -` as one pipeline: that opens the filename from
# the line relative to the working directory, which is not where the download
# was put, and under `set -euo pipefail` a grep matching nothing kills the
# script before any ::error can be printed.
fetch_verified() {
	local name="$1" dest="${WORK}/$1" want got
	fetch_sums
	want="$(published_sum "$name")"
	[[ -n "$want" ]] || die \
		"SHA512-SUMS.txt for Godot ${FULL} has no single entry for ${name}." \
		"" "Refusing to install an archive the release does not vouch for."

	echo "Downloading ${name}…" >&2
	curl -fsSL --retry 3 -o "$dest" "${BASE}/${name}" \
		|| die "Could not download ${name} from ${BASE}."

	got="$(sha512_of "$dest")"
	[[ "$got" == "$want" ]] || die \
		"${name} does not match the SHA-512 published with Godot ${FULL}." \
		"" "  expected ${want}" "  got      ${got}" "" \
		"The download was tampered with, truncated, or served from somewhere else."
	echo "  SHA-512 matches the published sum." >&2
	printf '%s' "$dest"
}

# ---------------------------------------------------------------------------
# The install manifest
# ---------------------------------------------------------------------------

# Every entry in the tree except the manifest, as sorted paths relative to it.
# Directories included: an added empty directory is a change to the tree, and
# ._sc_ is only the most damaging example of a stray entry mattering.
tree_files() { ( cd "$1" && find . -mindepth 1 ! -name "$MANIFEST" -printf '%P\n' | LC_ALL=C sort ); }

# Paths the manifest says should be there: the hashed files, plus the
# directories, which carry no hash.
manifest_files() {
	{
		# Braced so pipefail does not read "no hashed files" as a failure.
		{ grep -v '^#' "$1" || true; } | sed 's/^[0-9a-f]\{1,\}  //'
		sed -n 's/^# dir //p' "$1"
	} | LC_ALL=C sort
}

write_manifest() { # tree, archive name, archive sha512
	local tree="$1"
	{
		echo "# archive ${2}"
		echo "# archive-sha512 ${3}"
		( cd "$tree" && tree_files . | while IFS= read -r f; do
			# Today both archives unpack flat, so this only ever takes the else
			# branch. It is here so that an archive which one day ships a
			# subdirectory is recorded rather than handing sha512sum a directory
			# and breaking every build. A directory has nothing to hash, so it goes
			# in as a comment: the content check skips it, the set check reads it
			# back.
			if [[ -d "$f" ]]; then
				printf '# dir %s\n' "$f"
			else
				printf '%s  %s\n' "$(sha512_of "$f")" "$f"
			fi
		done )
	} > "${tree}/${MANIFEST}"
}

# Exact set, exact contents, and the archive it was built from still the one the
# release publishes.
#
# An extra file fails in its own right. An empty ._sc_ beside the editor puts
# Godot in self-contained mode, after which exports look for templates under
# ~/godot/editor_data/export_templates/ and fail -- while every hash here still
# matches and `godot --version` still answers.
verify_tree() { # tree, label, archive name
	local tree="$1" label="$2" archive="$3" recorded published expected actual

	recorded="$(awk '/^# archive-sha512 /{print $3; exit}' "${tree}/${MANIFEST}")"
	fetch_sums
	published="$(published_sum "$archive")"
	[[ -n "$recorded" && -n "$published" && "$recorded" == "$published" ]] || die \
		"The cached ${label} was not built from the archive Godot publishes for ${FULL}." \
		"" "  recorded  ${recorded:-(none)}" "  published ${published:-(none)}"

	expected="$(manifest_files "${tree}/${MANIFEST}")"
	actual="$(tree_files "$tree")"
	if [[ "$expected" != "$actual" ]]; then
		die "The cached ${label} does not hold the files it was installed with." \
			"" \
			"$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") \
				| sed -n 's/^< /  missing: /p; s/^> /  extra:   /p')" \
			"" \
			"An extra file is as serious as a missing one: an empty ._sc_ beside the" \
			"editor redirects export templates to a path that does not exist, and" \
			"every checksum still passes."
	fi

	( cd "$tree" && grep -v '^#' "$MANIFEST" | sha512sum -c --quiet - ) || die \
		"The cached ${label} has a file whose contents changed since it was installed."

	echo "  ${label}: $(printf '%s' "$actual" | grep -c . || true) file(s) verified."
}

# ---------------------------------------------------------------------------

# A tree with no manifest predates this check, or was written by something else.
# Reinstalling is both the safe answer and the self-healing one -- the fresh
# download is verified against the published sums before it is unpacked.
if [[ -x "${INSTALL_DIR}/godot" && -f "${INSTALL_DIR}/${MANIFEST}" ]]; then
	echo "Godot editor already present (cache hit) — verifying."
	verify_tree "$INSTALL_DIR" "editor" "$EDITOR_ARCHIVE"
else
	archive="$(fetch_verified "$EDITOR_ARCHIVE")"
	rm -rf "${INSTALL_DIR:?}"
	mkdir -p "$INSTALL_DIR"
	unzip -q -o "$archive" -d "${WORK}/editor"
	mv "${WORK}/editor/Godot_v${FULL}_linux.x86_64" "${INSTALL_DIR}/godot"
	chmod +x "${INSTALL_DIR}/godot"
	write_manifest "$INSTALL_DIR" "$EDITOR_ARCHIVE" "$(sha512_of "$archive")"
	echo "Installed the Godot ${FULL} editor."
fi

# Not `ls -A`: any one file made the directory look installed, so a partial
# restore reported a cache hit and the export failed much later, naming a
# template that had never been there.
if [[ -f "${TEMPLATE_DIR}/${MANIFEST}" ]]; then
	echo "Export templates already present (cache hit) — verifying."
	verify_tree "$TEMPLATE_DIR" "export templates" "$TEMPLATE_ARCHIVE"
else
	archive="$(fetch_verified "$TEMPLATE_ARCHIVE")"
	rm -rf "${TEMPLATE_DIR:?}"
	mkdir -p "$TEMPLATE_DIR"
	unzip -q -o "$archive" -d "${WORK}/templates"
	mv "${WORK}"/templates/templates/* "$TEMPLATE_DIR/"
	write_manifest "$TEMPLATE_DIR" "$TEMPLATE_ARCHIVE" "$(sha512_of "$archive")"
	echo "Installed the Godot ${FULL} export templates."
fi

"${INSTALL_DIR}/godot" --version
