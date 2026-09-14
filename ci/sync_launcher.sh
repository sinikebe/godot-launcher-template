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
for candidate in "$WORK/template/.github/workflows/"*.yml; do
	[[ -e "$candidate" ]] || continue
	name="$(basename "$candidate")"
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
	[[ -n "$CHANGED_LIST$MISSING_LIST" ]] || return 0

	if [[ -n "$CHANGED_LIST" ]]; then
		echo "Workflows changed upstream: ${CHANGED_LIST} (copy them by hand)"
	fi
	if [[ -n "$MISSING_LIST" ]]; then
		echo "Workflows new upstream, not present here: ${MISSING_LIST} (copy them by hand)"
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
	} >> "$GITHUB_STEP_SUMMARY"
}

# Called on both paths below, exactly once each.
emit_outputs() {
	[[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
	{
		echo "commit=${SHA}"
		echo "short_commit=${SHORT_SHA}"
		echo "subject=${SUBJECT}"
		echo "previous=${PREVIOUS_SHA}"
		echo "workflow_drift=${CHANGED_LIST}"
		echo "workflow_missing=${MISSING_LIST}"
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
