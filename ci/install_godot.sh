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
#
# A failed verification is deliberately terminal, not self-healing: the issue this
# implements asks for a changed, missing or extra file to fail the job, and a
# script that quietly reinstalled over the evidence would not do that. But
# actions/cache does not save over an entry whose primary key already matched, so
# the bad entry survives and every later run fails the same way. Recovery is to
# bump the cache key in the workflow (or delete the entry); the key carries a
# -verified-vN suffix so that is a one-character edit.
#
# For the same reason, adopting this script for the first time needs that key
# bumped once: an entry written before it has no manifest, so every run would
# reinstall and -- never being saved over -- would go on re-downloading 1.3 GB of
# export templates forever. Workflows are not synced, so a game updating its ci/
# must bump its own key by hand.
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
	# To stderr, not stdout: fetch_verified returns the archive path on stdout, so
	# a headline written there is swallowed by the command substitution that calls
	# it -- which is every download-path failure, i.e. exactly the ones the issue
	# asks to be named. Actions reads workflow commands from stderr too.
	echo "::error::$1" >&2
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
# The line has to match exactly: 128 hex, two spaces, then the name and nothing
# else. `grep -F "  $name"` was not enough -- it finds the name anywhere in the
# line, so a request for X.zip also matched the line for X.zip.sha256 and, when
# only that longer entry was present, returned a perfectly valid SHA-512 belonging
# to a different file. A name appearing only inside a comment returned "#". Both
# failed closed further down, but on a message blaming the download.
#
# Exactly one matching line is required, so a duplicated or ambiguous entry is
# treated as no entry at all.
published_sum() {
	local line sum name found="" result=""
	while IFS= read -r line; do
		# Tolerate a CRLF sums file; Godot publishes LF.
		line="${line%$'\r'}"
		sum="${line%%  *}"
		name="${line#*  }"
		[[ "$sum" =~ ^[0-9a-f]{128}$ ]] || continue
		[[ "$name" == "$1" ]] || continue
		[[ -z "$found" ]] || return 0
		found=1
		result="$sum"
	done < "$SUMS"
	printf '%s' "$result"
}

# The hash of one file. `--` so a name beginning with a dash is read as a
# filename rather than as options to sha512sum.
sha512_of() { sha512sum -- "$1" | cut -d' ' -f1; }

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
# ! -path, not ! -name: -name matches a basename at any depth, so a file called
# .verified-install.sha512 inside a subdirectory was excluded from the set check
# and could be added to a cached tree unnoticed.
tree_files() { ( cd "$1" && find . -mindepth 1 ! -path "./$MANIFEST" -printf '%P\n' | LC_ALL=C sort ); }

# Paths the manifest says should be there: the hashed files, plus the
# directories, which carry no hash.
manifest_files() {
	{
		# Braced so pipefail does not read "no hashed files" as a failure.
		{ grep -v '^#' "$1" || true; } | sed 's/^[0-9a-f]\{1,\}  //'
		sed -n 's/^# dir //p' "$1"
	} | LC_ALL=C sort
}

# A name holding a backslash or a newline cannot be written to a manifest
# faithfully: sha512sum escapes both, and a newline splits one path across two
# lines. Neither appears in Godot's archives, and refusing is honest where
# recording a name that cannot then be checked would not be.
# A tree that exists but carries no manifest was restored from a cache entry
# written before this script verified anything. Reinstalling is safe -- the fresh
# download is checked against the published sums -- but actions/cache does not save
# over an entry whose primary key already matched, so the entry stays
# manifest-less and every later run downloads the archives again, indefinitely.
# Only bumping the cache key fixes that, and workflows are not synced into
# consuming games, so the game has to do it. Said out loud rather than absorbed
# silently, because the symptom otherwise is just a slow build.
warn_if_stale_cache() { # tree, label
	[[ -d "$1" ]] || return 0
	[[ -n "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]] || return 0
	echo "::warning::The cached ${2} has no install manifest, so it predates this check; reinstalling. If this repeats on every run, bump the Godot cache key in .github/workflows/ -- actions/cache never saves over an entry whose key already matched, so the old entry cannot pick the manifest up on its own."
}

refuse_unrecordable_names() { # tree, label
	local tree="$1" label="$2" entries lines backslashed
	entries="$(find "$tree" -mindepth 1 -printf 'x' | wc -c)"
	lines="$(find "$tree" -mindepth 1 -printf '%P\n' | wc -l)"
	backslashed="$(find "$tree" -mindepth 1 -printf '%P\n' | grep -c '\\' || true)"
	if [[ "$entries" != "$lines" || "$backslashed" != "0" ]]; then
		die "The ${label} archive holds a path with a newline or a backslash in its name." \
			"" \
			"sha512sum escapes both, so such a name cannot be recorded in the install" \
			"manifest or checked against it later."
	fi
}

write_manifest() { # tree, archive name, archive sha512
	local tree="$1"
	{
		echo "# archive ${2}"
		echo "# archive-sha512 ${3}"
		# `sha512sum -- "$f"` rather than hashing through a command substitution:
		# it emits exactly the "<hash>  <name>" line `sha512sum -c` wants, and a
		# failure cannot be swallowed the way it is when the hash is one argument
		# of a printf -- which recorded an empty hash field and still exited 0.
		( cd "$tree" && tree_files . | while IFS= read -r f; do
			# Today both archives unpack flat, so this only ever takes the else
			# branch. It is here so that an archive which one day ships a
			# subdirectory is recorded rather than handing sha512sum a directory
			# and breaking every build. A directory has nothing to hash, so it goes
			# in as a comment; verify_tree checks it is still a directory.
			if [[ -d "$f" ]]; then
				printf '# dir %s\n' "$f"
			else
				sha512sum -- "$f"
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
	local tree="$1" label="$2" archive="$3" recorded published expected actual recorded_dir

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

	# An entry recorded as a directory carries no hash, so the contents check below
	# says nothing about it. Without this it only had to still exist under that
	# name: replacing a recorded empty directory with an arbitrary file, or with a
	# symlink, passed. -L as well as -d, because -d follows a symlink.
	while IFS= read -r recorded_dir; do
		[[ -d "${tree}/${recorded_dir}" && ! -L "${tree}/${recorded_dir}" ]] || die \
			"The cached ${label} has \"${recorded_dir}\", installed as a directory, replaced by something else."
	done < <(sed -n 's/^# dir //p' "${tree}/${MANIFEST}")

	# --strict: without it sha512sum exits 0 on a line it cannot parse, only
	# warning. So corrupting a hash field -- shortening it, say -- dropped that file
	# from the check entirely, and a tree whose contents had been replaced still
	# reported "N file(s) verified." and exit 0.
	( cd "$tree" && grep -v '^#' "$MANIFEST" | sha512sum -c --quiet --strict - ) || die \
		"The cached ${label} has a file whose contents changed since it was installed, or a manifest line that cannot be parsed."

	echo "  ${label}: $(printf '%s' "$actual" | grep -c . || true) file(s) verified."
}

# ---------------------------------------------------------------------------

# The manifest alone decides, for both trees: its presence means this tree was
# installed by a version of this script that verified it, so the tree must now
# answer for itself. A tree with no manifest predates the check, or was written by
# something else; reinstalling is both the safe answer and the self-healing one,
# because the fresh download is verified against the published sums before it is
# unpacked.
#
# The editor guard used to require `-x godot` as well, which inverted the
# intent: deleting the binary from a manifested tree made the guard false, so the
# script reinstalled in silence and exited 0 -- a missing file passing, when the
# issue asks for exactly that to fail the job.
if [[ -f "${INSTALL_DIR}/${MANIFEST}" ]]; then
	echo "Godot editor already present (cache hit) — verifying."
	verify_tree "$INSTALL_DIR" "editor" "$EDITOR_ARCHIVE"
else
	warn_if_stale_cache "$INSTALL_DIR" "editor"
	archive="$(fetch_verified "$EDITOR_ARCHIVE")"
	rm -rf "${INSTALL_DIR:?}"
	mkdir -p "$INSTALL_DIR"
	unzip -q -o "$archive" -d "${WORK}/editor"
	mv "${WORK}/editor/Godot_v${FULL}_linux.x86_64" "${INSTALL_DIR}/godot"
	chmod +x "${INSTALL_DIR}/godot"
	refuse_unrecordable_names "$INSTALL_DIR" "editor"
	write_manifest "$INSTALL_DIR" "$EDITOR_ARCHIVE" "$(sha512_of "$archive")"
	# The manifest is checked against the tree it was just written for, so a
	# manifest that cannot verify its own tree fails here rather than in whichever
	# later run happens to restore it -- quite possibly the release job.
	verify_tree "$INSTALL_DIR" "editor" "$EDITOR_ARCHIVE"
	echo "Installed the Godot ${FULL} editor."
fi

# Not `ls -A`: any one file made the directory look installed, so a partial
# restore reported a cache hit and the export failed much later, naming a
# template that had never been there.
if [[ -f "${TEMPLATE_DIR}/${MANIFEST}" ]]; then
	echo "Export templates already present (cache hit) — verifying."
	verify_tree "$TEMPLATE_DIR" "export templates" "$TEMPLATE_ARCHIVE"
else
	warn_if_stale_cache "$TEMPLATE_DIR" "export templates"
	archive="$(fetch_verified "$TEMPLATE_ARCHIVE")"
	rm -rf "${TEMPLATE_DIR:?}"
	mkdir -p "$TEMPLATE_DIR"
	unzip -q -o "$archive" -d "${WORK}/templates"
	mv "${WORK}"/templates/templates/* "$TEMPLATE_DIR/"
	refuse_unrecordable_names "$TEMPLATE_DIR" "export templates"
	write_manifest "$TEMPLATE_DIR" "$TEMPLATE_ARCHIVE" "$(sha512_of "$archive")"
	verify_tree "$TEMPLATE_DIR" "export templates" "$TEMPLATE_ARCHIVE"
	echo "Installed the Godot ${FULL} export templates."
fi

"${INSTALL_DIR}/godot" --version
