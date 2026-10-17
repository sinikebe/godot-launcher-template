#!/usr/bin/env bash
# Checks, before anything is built, that the release can be published where
# RELEASE_REPO says. release.yml runs it first, so a missing token or an unusable
# releases repository fails in seconds instead of after every export has run.
#
# Unset, or naming this repository, RELEASE_REPO publishes here as it always did,
# with github.token, and there is nothing to check. Naming another repository --
# a public one that holds only releases, for a game whose code is private -- needs:
#   * the RELEASE_TOKEN secret, because github.token can write only to this one;
#     the workflow says whether it is set in RELEASE_TOKEN_SET, and hands it to
#     gh as GH_TOKEN;
#   * a public repository, because players' apps download with no token at all;
#   * at least one commit in it, because GitHub cannot create a release tag in an
#     empty repository.
# It cannot tell whether the token may write there: any token can read a public
# repository. A token given the wrong repository fails at the publish step.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
RELEASE_REPO="${RELEASE_REPO:-$GITHUB_REPOSITORY}"

if [[ "${RUNNER_ENVIRONMENT:-}" == "self-hosted" ]]; then
	echo "::warning::This release runs on a self-hosted runner. The signing key and RELEASE_TOKEN are exposed to anything an earlier job left on it; see docs/UPDATES.md, \"Running the workflows on your own machine\"."
fi

# GitHub treats repository names without regard to case, and so does the
# workflow's own comparison when it picks the token.
if [[ "${RELEASE_REPO,,}" == "${GITHUB_REPOSITORY,,}" ]]; then
	echo "Releases are published to this repository, ${GITHUB_REPOSITORY}."
	exit 0
fi

# An owner is letters, digits and single hyphens; a repository name adds dot and
# underscore. Anything else is a typo, and it would end up in every URL the app
# polls.
if [[ ! "$RELEASE_REPO" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$ ]]; then
	echo "::error::RELEASE_REPO is '${RELEASE_REPO}', which is not an owner/name GitHub repository." >&2
	exit 1
fi

if [[ "${RELEASE_TOKEN_SET:-}" != "true" ]]; then
	echo "::error::RELEASE_REPO is ${RELEASE_REPO}, but there is no RELEASE_TOKEN secret." >&2
	printf '%s\n' \
		"The workflow's own token can publish only to ${GITHUB_REPOSITORY}. Add a" \
		"RELEASE_TOKEN secret: a fine-grained token with Contents: read and write on" \
		"${RELEASE_REPO} only. See docs/UPDATES.md, \"Publishing from a private repository\"." >&2
	exit 1
fi

# A classic token reaches every repository its owner can, the game's private
# source included, and it would ship code to every player. Matched by its prefix,
# or by the bare 40 hex digits of one made before 2021, with a builtin, so the
# token itself is never printed or put in argv.
if [[ "${GH_TOKEN:-}" == ghp_* || "${GH_TOKEN:-}" =~ ^[0-9a-f]{40}$ ]]; then
	echo "::error::RELEASE_TOKEN is a classic personal access token, which can reach every repository you can. Use a fine-grained token limited to ${RELEASE_REPO}." >&2
	exit 1
fi

if ! private="$(gh api "repos/${RELEASE_REPO}" --jq '.private' 2>/dev/null)"; then
	echo "::error::${RELEASE_REPO} does not exist, or is not visible to RELEASE_TOKEN." >&2
	exit 1
fi
if [[ "$private" != "false" ]]; then
	echo "::error::${RELEASE_REPO} is private. Players' apps download updates with no token, so they could never read its releases. Make it public; it holds only releases." >&2
	exit 1
fi

if ! gh api "repos/${RELEASE_REPO}/commits?per_page=1" --silent 2>/dev/null; then
	echo "::error::${RELEASE_REPO} has no commits, so GitHub cannot create a release tag in it. Add one, such as a README, and run the release again." >&2
	exit 1
fi

echo "Releases are published to ${RELEASE_REPO}."
