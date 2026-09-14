#!/usr/bin/env bash
# Pulls the launcher from the template repository into this project.
#
# Replaces addons/launcher/ and ci/ wholesale -- those directories are owned by
# the template and must never be edited in a consuming game, or the next sync
# silently reverts the edit. Everything a project legitimately changes lives in
# its LauncherConfig resource instead.
#
# Run this from a COPY outside ci/ (the workflow does), because the sync
# overwrites this very script while it is executing.
set -euo pipefail

TEMPLATE_REPO="${LAUNCHER_TEMPLATE_REPO:-sinikebe/godot-launcher-template}"
TEMPLATE_REF="${LAUNCHER_TEMPLATE_REF:-main}"

# Owned by the template. Anything outside these paths belongs to the game.
OWNED_PATHS=("addons/launcher" "ci")

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching ${TEMPLATE_REPO}@${TEMPLATE_REF}…"
git clone --quiet --depth 1 --branch "$TEMPLATE_REF" \
	"https://github.com/${TEMPLATE_REPO}.git" "$WORK/template"

SHA="$(git -C "$WORK/template" rev-parse HEAD)"
SHORT_SHA="$(git -C "$WORK/template" rev-parse --short=8 HEAD)"
SUBJECT="$(git -C "$WORK/template" log -1 --pretty=%s)"

RECORD="addons/launcher/.launcher-sync.json"
PREVIOUS_SHA=""
if [[ -f "$RECORD" ]]; then
	PREVIOUS_SHA="$(python3 -c "
import json, sys
try:
    print(json.load(open('$RECORD', encoding='utf-8')).get('commit', ''))
except Exception:
    print('')
")"
fi

# GITHUB_TOKEN is not allowed to write .github/workflows/, so the starter
# workflows cannot be synced automatically. Detect when they have drifted and
# say so, rather than letting a game silently run year-old CI.
#
# Deliberately ABOVE the "already up to date" exit below. Workflows drift
# independently of the launcher SHA -- that is the entire premise of the check
# -- so running it after that exit made it unreachable in exactly the steady
# state it was written for: once a game merges its sync pull request,
# PREVIOUS_SHA equals SHA on every later scheduled run, and the check never ran
# again.
WORKFLOW_CHANGED=()
WORKFLOW_MISSING=()
WORKFLOW_REJECTED=0
for candidate in "$WORK/template/.github/workflows/"*.yml; do
	[[ -e "$candidate" ]] || continue
	name="$(basename "$candidate")"
	# This name comes from the TEMPLATE repository, so it is attacker-controlled
	# if that repository is compromised. Git allows every byte but "/" and NUL in
	# a filename, and this one reaches three places that give a newline meaning:
	# $GITHUB_OUTPUT, which the runner parses line by line -- so an embedded
	# newline forges step outputs, and a forged empty workflow_drift erases this
	# very warning -- plus $GITHUB_STEP_SUMMARY and a pull request body, both
	# rendered as markdown. A real workflow filename is none of those things, so
	# anything else is counted and never echoed.
	if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.yml$ ]]; then
		WORKFLOW_REJECTED=$((WORKFLOW_REJECTED + 1))
		continue
	fi
	mine=".github/workflows/${name}"
	if [[ ! -f "$mine" ]]; then
		# Upstream-only: the template added a workflow, or split an existing one
		# in two. The old check required the file to exist here before comparing
		# it, so this case was skipped entirely -- and it is the one kind of
		# drift a game cannot notice for itself, because there is nothing on
		# disk to look at.
		WORKFLOW_MISSING+=("$name")
	elif ! diff -q "$candidate" "$mine" >/dev/null 2>&1; then
		WORKFLOW_CHANGED+=("$name")
	fi
done

# "${array[*]}" joins on the first character of IFS and adds no separator at the
# end. The previous string form accumulated "${name} " and carried a trailing
# space into the pull request body, where it rendered inside the backticks.
CHANGED_LIST=""
MISSING_LIST=""
if (( ${#WORKFLOW_CHANGED[@]} > 0 )); then
	CHANGED_LIST="${WORKFLOW_CHANGED[*]}"
fi
if (( ${#WORKFLOW_MISSING[@]} > 0 )); then
	MISSING_LIST="${WORKFLOW_MISSING[*]}"
fi

# Report to the job log and to the run summary.
#
# The run summary is what makes this reachable at all. When the launcher is
# already up to date the workflow opens no pull request, and the PR body was
# the only human-facing surface this note ever reached. $GITHUB_STEP_SUMMARY is
# written here, by the script itself, so it does not depend on a later step
# running.
drift_report() {
	if [[ -z "$CHANGED_LIST$MISSING_LIST" ]] && (( WORKFLOW_REJECTED == 0 )); then
		return 0
	fi

	# ::warning:: rather than a plain echo: a sync run that finds nothing to sync
	# is green and uneventful, and nobody opens the log of a green run. An
	# annotation surfaces in the Actions list without one. Safe to build from
	# these names only because the guard above rejected any that are not plain.
	if [[ -n "$CHANGED_LIST" ]]; then
		echo "::warning::Workflows changed upstream and must be copied by hand: ${CHANGED_LIST}"
	fi
	if [[ -n "$MISSING_LIST" ]]; then
		echo "::warning::Workflows are new upstream and not present here; copy them by hand: ${MISSING_LIST}"
	fi
	if (( WORKFLOW_REJECTED > 0 )); then
		echo "::warning::${WORKFLOW_REJECTED} upstream workflow filename(s) are not plain names; not reported by name."
	fi

	[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
	{
		echo "### Workflows need copying by hand"
		echo
		echo "A token scoped to \`contents\` cannot write \`.github/workflows/\`, so the sync leaves these alone:"
		echo
		if [[ -n "$CHANGED_LIST" ]]; then
			echo "- **Changed upstream:** \`${CHANGED_LIST}\`"
		fi
		if [[ -n "$MISSING_LIST" ]]; then
			echo "- **New upstream, not present here:** \`${MISSING_LIST}\`"
		fi
		echo
		echo '```bash'
		echo "git clone --depth 1 https://github.com/${TEMPLATE_REPO}.git /tmp/launcher-template"
		echo "cp /tmp/launcher-template/.github/workflows/*.yml .github/workflows/"
		echo "rm -rf /tmp/launcher-template"
		echo '```'
	} >> "$GITHUB_STEP_SUMMARY" || echo "::warning::Could not write the run summary; the log above is the only copy."
	# This function runs BEFORE the sync, and set -e would make the group above
	# the function's exit status. A reporting failure must not become a total
	# sync failure.
	return 0
}

# Called on both paths below, exactly once each.
emit_outputs() {
	[[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
	# key<<DELIM / value / DELIM, with a delimiter no value can contain. The plain
	# key=value form is read line by line by the runner, so a newline anywhere in
	# a value starts a line the runner accepts as another output key. The guard in
	# the drift loop already keeps newlines out of these two values; this closes
	# the shape of the bug rather than one instance of it, and covers whatever the
	# next output added here happens to be.
	local delim
	delim="ghadelim_$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
	{
		printf 'commit<<%s\n%s\n%s\n'           "$delim" "$SHA"          "$delim"
		printf 'short_commit<<%s\n%s\n%s\n'     "$delim" "$SHORT_SHA"    "$delim"
		printf 'subject<<%s\n%s\n%s\n'          "$delim" "$SUBJECT"      "$delim"
		printf 'previous<<%s\n%s\n%s\n'         "$delim" "$PREVIOUS_SHA" "$delim"
		printf 'workflow_drift<<%s\n%s\n%s\n'   "$delim" "$CHANGED_LIST" "$delim"
		printf 'workflow_missing<<%s\n%s\n%s\n' "$delim" "$MISSING_LIST" "$delim"
	} >> "$GITHUB_OUTPUT"
}

drift_report

if [[ "$PREVIOUS_SHA" == "$SHA" ]]; then
	echo "Already on ${SHORT_SHA}; nothing to do."
	emit_outputs
	exit 0
fi

for path in "${OWNED_PATHS[@]}"; do
	if [[ ! -d "$WORK/template/$path" ]]; then
		echo "::error::Template has no ${path}; refusing to sync a partial launcher." >&2
		exit 1
	fi
	rm -rf "${ROOT:?}/$path"
	mkdir -p "$(dirname "$ROOT/$path")"
	cp -R "$WORK/template/$path" "$ROOT/$path"
done

# Stamp the launcher's own version so the game can report, on screen, exactly
# which revision of the launcher it is running. A .json record is not enough:
# dotfiles are not exported into the shipped pack, and a GDScript constant is.
python3 - "$SHORT_SHA" "$TEMPLATE_REPO" <<'PYEOF'
import datetime, pathlib, re, sys

short_sha, repo = sys.argv[1], sys.argv[2]
path = pathlib.Path("addons/launcher/launcher_version.gd")
text = path.read_text(encoding="utf-8")
stamped = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

# VERSION is the template's to declare and travels with the copied file.
for const, value in (("COMMIT", short_sha), ("SYNCED_AT", stamped), ("SOURCE", repo)):
    text = re.sub(rf'^const {const}: String = ".*"$',
                  f'const {const}: String = "{value}"', text, count=1, flags=re.M)
path.write_text(text, encoding="utf-8")
PYEOF

python3 - "$RECORD" "$TEMPLATE_REPO" "$TEMPLATE_REF" "$SHA" "$SUBJECT" <<'PY'
import datetime, json, sys

record, repo, ref, sha, subject = sys.argv[1:6]
with open(record, "w", encoding="utf-8") as fh:
    json.dump({
        "_comment": "Written by ci/sync_launcher.sh. Do not edit addons/launcher/ or ci/ by hand -- the next sync overwrites them.",
        "source": repo,
        "ref": ref,
        "commit": sha,
        "subject": subject,
        "synced_at": datetime.datetime.now(datetime.timezone.utc)
            .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }, fh, indent=2)
    fh.write("\n")
PY

echo "Synced launcher to ${SHORT_SHA} — ${SUBJECT}"

emit_outputs
