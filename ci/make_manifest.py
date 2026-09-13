#!/usr/bin/env python3
"""Build the update manifest the app polls, from the artifacts CI just produced.

The manifest is published as a release asset named ``manifest.json`` and fetched
by the app from ``releases/latest/download/manifest.json`` -- a path that always
redirects to the newest release, so a shipped build never has to know a release
tag, call the GitHub API, or deal with rate limits.

The artifact URLs inside it, however, are pinned to *this* release's tag rather
than to ``latest``. That matters: GitHub's CDN caches the two paths
independently, so during a release there is a window where
``latest/download/manifest.json`` still serves the previous release while
``latest/download/<game>.apk`` already serves the new one. Tag-pinned URLs make
each manifest internally consistent -- a client that gets a stale manifest simply
installs that slightly older release and catches up on its next check, instead of
pairing one release's checksum with another release's bytes and failing.

Every artifact is hashed here, and the app refuses to install a download whose
SHA-256 does not match.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import pathlib
import sys
import urllib.parse

SCHEMA_VERSION = 1
VALID_KINDS = ("binary", "content")

# The manifest is fetched on every launch, so the changelog it carries is capped.
MAX_CHANGELOG_ENTRIES = 20
MAX_CHANGES_PER_ENTRY = 20


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_artifact(raw: str) -> tuple[str, str, pathlib.Path]:
    """Parse a ``kind:platform:path`` triple, e.g. ``binary:android:build/x.apk``."""
    try:
        kind, platform, path = raw.split(":", 2)
    except ValueError:
        raise SystemExit(f"--artifact must be kind:platform:path, got {raw!r}")
    if kind not in VALID_KINDS:
        raise SystemExit(f"unknown artifact kind {kind!r}, expected one of {VALID_KINDS}")
    resolved = pathlib.Path(path)
    if not resolved.is_file():
        raise SystemExit(f"artifact not found: {resolved}")
    return kind, platform, resolved


def load_json(path: pathlib.Path | None) -> object:
    """Best-effort read; a missing or unreadable file is simply 'nothing yet'."""
    if path is None or not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        print(f"warning: ignoring {path}: {exc}", file=sys.stderr)
        return None


def build_changelog(args, released_at: str) -> list[dict]:
    """This release's entry, prepended to the history the last one carried.

    A player several releases behind should see everything since their build,
    so the whole recent history travels in every manifest rather than only the
    newest entry. Older entries are dropped past MAX_CHANGELOG_ENTRIES to keep
    the manifest small -- it is fetched on every launch.
    """
    changes = load_json(args.changes_file) or []
    if not isinstance(changes, list):
        changes = []

    entry = {
        "content_version": args.content_version,
        "binary_version": args.binary_version,
        "version_name": args.version_name,
        "released_at": released_at,
        "changes": [str(c) for c in changes][:MAX_CHANGES_PER_ENTRY],
    }

    previous = load_json(args.previous_manifest)
    history: list[dict] = []
    if isinstance(previous, dict) and isinstance(previous.get("changelog"), list):
        history = [
            item
            for item in previous["changelog"]
            if isinstance(item, dict)
            # Guard against a rerun of the same release duplicating its entry.
            and item.get("content_version") != args.content_version
        ]

    return [entry] + history[: MAX_CHANGELOG_ENTRIES - 1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="owner/name on GitHub")
    parser.add_argument("--version-name", required=True)
    parser.add_argument("--binary-version", required=True, type=int)
    parser.add_argument("--content-version", required=True, type=int)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument(
        "--artifact",
        action="append",
        default=[],
        metavar="KIND:PLATFORM:PATH",
        help="repeatable; KIND is 'binary' or 'content'",
    )
    parser.add_argument(
        "--changes-file",
        type=pathlib.Path,
        help="JSON array of this release's change lines (from collect_changes.sh)",
    )
    parser.add_argument(
        "--previous-manifest",
        type=pathlib.Path,
        help="the previous release's manifest, whose changelog is carried forward",
    )
    parser.add_argument("--out", required=True, type=pathlib.Path)
    args = parser.parse_args()

    # quote() so a tag containing "+" (build metadata, as in v0.1.0+7) survives
    # every HTTP client unambiguously.
    base_url = (
        f"https://github.com/{args.repo}/releases/download/"
        f"{urllib.parse.quote(args.tag, safe='')}"
    )
    artifacts: dict[str, dict[str, dict]] = {kind: {} for kind in VALID_KINDS}

    for raw in args.artifact:
        kind, platform, path = parse_artifact(raw)
        artifacts[kind][platform] = {
            "file": path.name,
            "url": f"{base_url}/{path.name}",
            "size": path.stat().st_size,
            "sha256": sha256_of(path),
        }

    released_at = (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )

    manifest = {
        "schema": SCHEMA_VERSION,
        "version_name": args.version_name,
        "binary_version": args.binary_version,
        "content_version": args.content_version,
        "commit": args.commit,
        "release_tag": args.tag,
        "released_at": released_at,
        "artifacts": artifacts,
        "changelog": build_changelog(args, released_at),
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
