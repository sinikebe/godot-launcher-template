#!/usr/bin/env bash
# Fails a pull request that changes addons/launcher/ without bumping
# LauncherVersion.VERSION.
#
# VERSION is hand-maintained -- the sync stamps COMMIT, SYNCED_AT and SOURCE, and
# deliberately leaves VERSION alone, because it is the template's to declare.
# Hand-maintained meant nothing maintained it: it sat at 1.0.0 across four
# changes to addons/launcher/, one of which removed a public constant
# (UpdateService.REQUEST_TIMEOUT). Code written against "launcher 1.0.0" failed
# against "launcher 1.0.0".
#
# Every failure path here is loud. A check that cannot see the diff must not
# report success: that is the same shape as the bug it exists to prevent.
#
#   bash ci/check_launcher_version.sh <base-ref> [head-ref]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION_FILE="addons/launcher/launcher_version.gd"
RECORD="addons/launcher/.launcher-sync.json"

ARGC=$#
BASE="${1:-}"
HEAD_ARG="${2:-}"

if [[ -z "$BASE" ]]; then
	echo "usage: bash ci/check_launcher_version.sh <base-ref> [head-ref]" >&2
	exit 2
fi

die() { # every abort prints an annotation and exits non-zero
	echo "::error file=${VERSION_FILE}::$1" >&2
	shift
	[[ $# -gt 0 ]] && printf '%s\n' "$@" >&2
	exit 1
}

# Only the repository that OWNS the launcher can set its version.
#
# ci/ is synced into consuming games wholesale, so this script travels with it.
# In a game, addons/launcher/ changes only by sync -- and the sync writes COMMIT,
# never VERSION. Enforcing there would fail every sync pull request, blocking the
# launcher update it exists to deliver, over a value the game cannot set. The
# sync record is the distinction, and an intrinsic one: it exists only in a
# repository that pulled the launcher in from elsewhere, so this needs no
# hardcoded repository name and survives a fork of the template.
#
# A game created from the template has no record until its first sync, so in that
# window a hand edit to addons/launcher/ is asked for a bump it should not have
# to make. The label below is the way out, and the window closes on the next
# scheduled sync.
#
# ::notice:: rather than a bare echo: skipping is how this check stops checking,
# and a check that has silently stopped checking should say so where someone
# scanning the Actions list can see it.
if [[ -f "$RECORD" ]]; then
	# Warn when this branch is what introduced the record. A game's genuine first
	# sync adds it in the same pull request that brings the launcher in, so this
	# cannot be an error -- but it is also the one way an author can switch the
	# check off for their own pull request, so it does not pass silently.
	if [[ -n "${1:-}" ]] && ! git cat-file -e "${1}:${RECORD}" 2>/dev/null; then
		echo "::warning::${RECORD} is added by this branch, which turns the launcher bump check off for it. Expected on a game's first sync; unexpected anywhere else."
	fi
	echo "::notice::${RECORD} is present, so this repository syncs its launcher from upstream and VERSION is upstream's to set. Bump check skipped."
	exit 0
fi

# --- What this pull request actually contributes ----------------------------
#
# NOT `git diff <base.sha> HEAD`. On a pull_request run the checkout is
# refs/pull/N/merge, and base.sha is a snapshot from when the event fired --
# replayed unchanged by every "Re-run jobs". Two-dot against a stale base tip
# reports everything that landed on the base branch since, so a pull request
# could pass by riding a bump someone else merged. Diff from the merge base of
# the branch under review instead, which is the same answer either way.
#
# The workflow passes that branch's head explicitly. It was briefly inferred
# from `HEAD^2` -- "two parents means this is the merge ref" -- which is not the
# same statement: an author who merges main into their own branch to stay
# current also produces a two-parent HEAD, and there HEAD^2 is the main side, so
# the merge base collapsed to main's tip and the diff came back empty. Green,
# having compared nothing. The head is a fact the caller has; it is not guessed.
if (( ARGC >= 2 )); then
	# Passed, so it must be usable. An empty value here would otherwise fall
	# through to HEAD -- the merge ref -- which is the shape this round removed,
	# and the check would quietly credit someone else's bump to this branch.
	if [[ -z "$HEAD_ARG" ]]; then
		die "An empty head ref was passed; the launcher version was not checked."
	fi
	if ! HEAD_COMMIT="$(git rev-parse --verify --quiet "$HEAD_ARG^{commit}")"; then
		die "Could not resolve the head ref '${HEAD_ARG}'; the launcher version was not checked."
	fi
else
	HEAD_COMMIT="$(git rev-parse HEAD)"
fi

if [[ -z "$HEAD_ARG" ]] && ! git diff --quiet -- addons/launcher/; then
	echo "note: addons/launcher/ has uncommitted changes. This compares commits and will not see them." >&2
fi

if ! MERGE_BASE="$(git merge-base "$BASE" "$HEAD_COMMIT" 2>/dev/null)"; then
	die "Could not find a merge base between ${BASE} and ${HEAD_COMMIT}; the launcher version was not checked." \
		"" \
		"A shallow checkout cannot compute one -- the job needs 'fetch-depth: 0' --" \
		"and neither can a base ref that is no longer reachable. Failing rather than" \
		"passing: a check that cannot see the diff has not checked anything."
fi

if ! DIFF="$(git diff --name-only "$MERGE_BASE" "$HEAD_COMMIT" -- addons/launcher/ 2>/dev/null)"; then
	die "Could not diff addons/launcher/ between ${MERGE_BASE} and ${HEAD_COMMIT}; the launcher version was not checked."
fi

# .uid sidecars are regenerated by the Godot editor and carry no behaviour, so a
# change confined to them is not a launcher change. Excluded from the trigger,
# not from the diff: a .uid that moves alongside real edits is fine, it just
# cannot be the only thing that moved.
CHANGED=()
while IFS= read -r path; do
	[[ -n "$path" ]] || continue
	[[ "$path" == *.uid ]] && continue
	CHANGED+=("$path")
done <<< "$DIFF"

if (( ${#CHANGED[@]} == 0 )); then
	echo "No behavioural change under addons/launcher/; nothing to check."
	exit 0
fi

# Absent at a ref is not an error: the launcher may be added by this pull
# request, or removed by it. `git show` exits 128 there, which under
# `set -o pipefail` would kill the script before it could say anything.
read_version() { # $1 = git ref -- prints the version, or nothing if unreadable
	local text
	text="$(git show "$1:$VERSION_FILE" 2>/dev/null)" || return 0
	# awk not `sed | head`: one process, so no SIGPIPE for pipefail to promote.
	awk -F'"' '/^const VERSION: String = /{print $2; exit}' <<< "$text"
}

BASE_VERSION="$(read_version "$MERGE_BASE")"
HEAD_VERSION="$(read_version "$HEAD_COMMIT")"

VERSION_LINE="$(awk '/^const VERSION: String = /{print NR; exit}' "$VERSION_FILE" 2>/dev/null || true)"
[[ -n "$VERSION_LINE" ]] || VERSION_LINE=1

# Strict: semver forbids leading zeros in a numeric identifier, and admitting
# them means "1.0.010" and "1.0.10" are two spellings of one version. The
# comparison below orders them correctly either way; this just refuses to accept
# a spelling that reads as two different things.
is_semver() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

# $1 > $2, component by component.
#
# No arithmetic on the components. `(( 09 > 08 ))` is an octal parse error, and
# is_semver admits leading zeros, so a date-shaped 2026.08.30 -> 2026.09.14 came
# back as "went backwards" with raw bash errors in the annotation stream. A long
# enough component overflows int64 and wraps. Comparing digit strings by length
# and then lexicographically is the same ordering, for any length, in any base.
version_gt() {
	local -a a b
	IFS=. read -ra a <<< "$1"
	IFS=. read -ra b <<< "$2"
	local i x y
	for i in 0 1 2; do
		x="${a[i]:-0}"; y="${b[i]:-0}"
		x="${x#"${x%%[!0]*}"}"; x="${x:-0}"
		y="${y#"${y%%[!0]*}"}"; y="${y:-0}"
		if (( ${#x} != ${#y} )); then
			if (( ${#x} > ${#y} )); then return 0; else return 1; fi
		fi
		if [[ "$x" > "$y" ]]; then return 0; fi
		if [[ "$x" < "$y" ]]; then return 1; fi
	done
	return 1
}

# Removing the launcher wholesale is legitimate and leaves no version to bump.
# Removing only the version file, while the rest of addons/launcher/ stays and
# changes, is not: that is deleting the thing being checked.
if ! git cat-file -e "${HEAD_COMMIT}:${VERSION_FILE}" 2>/dev/null; then
	if [[ -z "$(git ls-tree -r --name-only "$HEAD_COMMIT" -- addons/launcher/ 2>/dev/null)" ]]; then
		echo "addons/launcher/ is gone at the head commit; nothing to bump."
		exit 0
	fi
	die "${VERSION_FILE} was removed, but the rest of addons/launcher/ is still here and changed." \
		"" "Remove the launcher entirely, or keep the file that says which one it is."
fi

if [[ -z "$HEAD_VERSION" ]]; then
	die "Could not read VERSION from ${VERSION_FILE}." \
		"" "Expected a line of the form:  const VERSION: String = \"x.y.z\""
fi

# The label is checked here, above the shape and ordering rules rather than
# below them, because "your VERSION is malformed" is just as much a thing a
# maintainer may want to wave through as "you did not bump". It still sits below
# the aborts above, which are not judgements -- they are the check reporting it
# could not run.
if [[ "${LAUNCHER_VERSION_EXEMPT:-}" == "true" ]]; then
	echo "::notice::addons/launcher/ changed with VERSION held at ${HEAD_VERSION}, by label."
	exit 0
fi

if ! is_semver "$HEAD_VERSION"; then
	die "VERSION is \"${HEAD_VERSION}\", which is not MAJOR.MINOR.PATCH with no leading zeros." \
		"" \
		"Write 2026.9.14, not 2026.09.14: a leading zero makes \"1.0.010\" and \"1.0.10\"" \
		"two spellings of one version. If this really should not change, label the" \
		"pull request 'no-launcher-bump'."
fi

# "Empty at base" is three different facts, and only one of them is benign.
# read_version returns empty for an unreadable ref, for an absent file, and for
# a file whose declaration is not in the exact expected form -- so asserting
# "the launcher is being added" without checking passed a pull request that had
# merely reformatted the declaration while changing the launcher.
if [[ -z "$BASE_VERSION" ]]; then
	if ! git cat-file -e "${MERGE_BASE}:${VERSION_FILE}" 2>/dev/null; then
		echo "Launcher added at VERSION ${HEAD_VERSION}. ${#CHANGED[@]} file(s)."
		exit 0
	fi
	die "${VERSION_FILE} exists at the merge base but no VERSION could be read from it." \
		"" "Expected a line of the form:  const VERSION: String = \"x.y.z\"" \
		"Refusing to treat an unreadable base version as \"the launcher is new\"."
fi

# What a maintainer may WRITE is strict; what can be ORDERED is not the same
# question. Tightening is_semver moved every leading-zero base version out of
# the ordered comparison and into the "any change is progress" branch below,
# where going backwards passed: a base of 2026.08.30 accepted a head of 0.0.0
# with the launcher gutted. version_gt strips leading zeros precisely so it can
# order these, so it is asked whenever the base is orderable at all.
is_orderable() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

if is_orderable "$BASE_VERSION"; then
	if version_gt "$HEAD_VERSION" "$BASE_VERSION"; then
		echo "VERSION bumped ${BASE_VERSION} -> ${HEAD_VERSION}. ${#CHANGED[@]} launcher file(s) changed."
		exit 0
	fi
elif [[ "$BASE_VERSION" != "$HEAD_VERSION" ]]; then
	# Base is not even three numbers -- nothing to order against, so any change
	# to a well-formed version is the best signal available.
	echo "VERSION moved ${BASE_VERSION} -> ${HEAD_VERSION}. ${#CHANGED[@]} launcher file(s) changed."
	exit 0
fi

if [[ "$BASE_VERSION" == "$HEAD_VERSION" ]]; then
	HEADLINE="addons/launcher/ changed but LauncherVersion.VERSION is still ${HEAD_VERSION}."
else
	HEADLINE="LauncherVersion.VERSION went backwards, ${BASE_VERSION} -> ${HEAD_VERSION}."
fi

{
	echo "::error file=${VERSION_FILE},line=${VERSION_LINE}::${HEADLINE} Bump it, or label the pull request 'no-launcher-bump'."
	echo
	echo "These launcher files changed:"
	printf '  %s\n' "${CHANGED[@]}"
	echo
	echo "Which component moves is a judgement:"
	echo "  MAJOR  a game's existing code stops compiling -- a removed or renamed const,"
	echo "         signal, or exported property, or a changed method signature"
	echo "  MINOR  new public surface that existing code does not have to care about"
	echo "  PATCH  a fix with no interface change"
	echo
	echo "If this genuinely does not warrant a bump -- a comment, a typo -- add the"
	echo "'no-launcher-bump' label. Labelling re-runs this check on its own."
} >&2
exit 1
