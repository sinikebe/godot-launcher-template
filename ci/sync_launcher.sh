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

if [[ "$PREVIOUS_SHA" == "$SHA" ]]; then
	echo "Already on ${SHORT_SHA}; nothing to do."
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

# GITHUB_TOKEN is not allowed to write .github/workflows/, so the starter
# workflows cannot be synced automatically. Detect when they have drifted and
# say so, rather than letting a game silently run year-old CI.
WORKFLOW_DRIFT=""
for candidate in "$WORK/template/template/.github/workflows/"*.yml; do
	[[ -e "$candidate" ]] || continue
	name="$(basename "$candidate")"
	mine=".github/workflows/${name}"
	if [[ -f "$mine" ]] && ! diff -q "$candidate" "$mine" >/dev/null 2>&1; then
		WORKFLOW_DRIFT+="${name} "
	fi
done
if [[ -n "$WORKFLOW_DRIFT" ]]; then
	echo "Workflows differ from the template: ${WORKFLOW_DRIFT}(copy them by hand)"
fi

echo "Synced launcher to ${SHORT_SHA} — ${SUBJECT}"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	{
		echo "commit=${SHA}"
		echo "short_commit=${SHORT_SHA}"
		echo "subject=${SUBJECT}"
		echo "previous=${PREVIOUS_SHA}"
		echo "workflow_drift=${WORKFLOW_DRIFT}"
	} >> "$GITHUB_OUTPUT"
fi
