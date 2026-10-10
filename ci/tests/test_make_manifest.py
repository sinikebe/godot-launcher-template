"""Tests for ci/make_manifest.py -- the manifest every player's app polls.

A mistake here ships as a broken or misleading update, and nothing else in CI
runs this script before a release does. Standard library only (unittest), so it
needs no install step:

    python3 -m unittest discover -s ci/tests -v
"""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import types
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("make_manifest", HERE.parent / "make_manifest.py")
mm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mm)


def args(tmp: pathlib.Path, *, content_version=3, changes=None, previous=None, binary_version=1):
    """The attributes build_changelog() reads, with the files written to tmp."""
    changes_file = None
    if changes is not None:
        changes_file = tmp / "changes.json"
        changes_file.write_text(json.dumps(changes), encoding="utf-8")
    previous_file = None
    if previous is not None:
        previous_file = tmp / "previous.json"
        previous_file.write_text(
            previous if isinstance(previous, str) else json.dumps(previous), encoding="utf-8")
    return types.SimpleNamespace(
        content_version=content_version,
        binary_version=binary_version,
        version_name="1.0.%d" % content_version,
        changes_file=changes_file,
        previous_manifest=previous_file,
    )


def entry(content_version: int, changes=("x",)):
    return {"content_version": content_version, "binary_version": 1,
            "version_name": "v%d" % content_version, "released_at": "t", "changes": list(changes)}


class BuildChangelog(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._dir.name)
        self.addCleanup(self._dir.cleanup)

    def build(self, **kw):
        with contextlib.redirect_stderr(io.StringIO()):
            return mm.build_changelog(args(self.tmp, **kw), "2026-01-01T00:00:00Z")

    def test_first_release_has_one_entry(self):
        log = self.build(changes=["a", "b"])
        self.assertEqual([e["content_version"] for e in log], [3])
        self.assertEqual(log[0]["changes"], ["a", "b"])
        self.assertEqual(log[0]["released_at"], "2026-01-01T00:00:00Z")

    def test_new_entry_goes_first_and_history_is_carried_forward(self):
        log = self.build(changes=["new"], previous={"changelog": [entry(2), entry(1)]})
        self.assertEqual([e["content_version"] for e in log], [3, 2, 1])

    def test_rerun_of_same_release_replaces_its_entry(self):
        log = self.build(changes=["fresh"], previous={"changelog": [entry(3, ["stale"]), entry(2)]})
        self.assertEqual([e["content_version"] for e in log], [3, 2])
        self.assertEqual(log[0]["changes"], ["fresh"])

    def test_history_is_capped(self):
        previous = {"changelog": [entry(v) for v in range(30, 3, -1)]}
        log = self.build(previous=previous)
        self.assertEqual(len(log), mm.MAX_CHANGELOG_ENTRIES)
        self.assertEqual(log[0]["content_version"], 3)
        self.assertEqual(log[1]["content_version"], 30)  # newest history kept, oldest dropped

    def test_changes_per_entry_are_capped_and_stringified(self):
        log = self.build(changes=list(range(mm.MAX_CHANGES_PER_ENTRY + 5)))
        self.assertEqual(len(log[0]["changes"]), mm.MAX_CHANGES_PER_ENTRY)
        self.assertTrue(all(isinstance(c, str) for c in log[0]["changes"]))

    def test_non_list_changes_file_means_no_changes(self):
        self.assertEqual(self.build(changes={"not": "a list"})[0]["changes"], [])

    def test_missing_or_unreadable_previous_manifest_is_nothing_yet(self):
        self.assertEqual(len(self.build()), 1)
        self.assertEqual(len(self.build(previous="{not json")), 1)

    def test_malformed_previous_changelog_is_ignored(self):
        self.assertEqual(len(self.build(previous={"changelog": "nope"})), 1)
        self.assertEqual(len(self.build(previous=[1, 2])), 1)
        # non-dict items inside a valid list are dropped, dict items kept
        log = self.build(previous={"changelog": [entry(2), "junk", 7]})
        self.assertEqual([e["content_version"] for e in log], [3, 2])


class ParseArtifact(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.file = pathlib.Path(self._dir.name) / "game.apk"
        self.file.write_bytes(b"apk")

    def test_valid_triple(self):
        kind, platform, path = mm.parse_artifact("binary:android:%s" % self.file)
        self.assertEqual((kind, platform, path), ("binary", "android", self.file))

    def test_path_may_contain_colons(self):
        # split(":", 2): everything after the second colon is the path
        odd = pathlib.Path(self._dir.name) / "a:b.pck"
        odd.write_bytes(b"x")
        self.assertEqual(mm.parse_artifact("content:android:%s" % odd)[2], odd)

    def test_rejects_malformed_unknown_kind_and_missing_file(self):
        for bad in ("nonsense", "binary:android", "weird:android:%s" % self.file,
                    "binary:android:%s/nope" % self.file.parent):
            with self.subTest(bad=bad), self.assertRaises(SystemExit):
                mm.parse_artifact(bad)


class EndToEnd(unittest.TestCase):
    """Runs main() the way release.yml does and checks what the app would read."""

    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.tmp = pathlib.Path(self._dir.name)

    def run_main(self, *extra, tag="v0.1.0+7"):
        out = self.tmp / "out" / "manifest.json"
        argv = ["make_manifest.py", "--repo", "me/game", "--version-name", "0.1.0",
                "--binary-version", "2", "--content-version", "7", "--commit", "abc",
                "--tag", tag, "--out", str(out), *extra]
        old = sys.argv
        sys.argv = argv
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(mm.main(), 0)
        finally:
            sys.argv = old
        return json.loads(out.read_text(encoding="utf-8"))

    def test_manifest_shape_hashes_and_tag_pinned_urls(self):
        apk = self.tmp / "game.apk"
        apk.write_bytes(b"binary bytes")
        pck = self.tmp / "content-android.pck"
        pck.write_bytes(b"pack bytes")
        m = self.run_main("--artifact", "binary:android:%s" % apk,
                          "--artifact", "content:android:%s" % pck)

        self.assertEqual(m["schema"], mm.SCHEMA_VERSION)
        self.assertEqual((m["binary_version"], m["content_version"]), (2, 7))
        self.assertEqual(m["release_tag"], "v0.1.0+7")
        self.assertTrue(m["released_at"].endswith("Z"))

        binary = m["artifacts"]["binary"]["android"]
        self.assertEqual(binary["sha256"], hashlib.sha256(b"binary bytes").hexdigest())
        self.assertEqual(binary["size"], len(b"binary bytes"))
        # pinned to this release's tag, with "+" escaped, never to "latest"
        self.assertEqual(binary["url"],
                         "https://github.com/me/game/releases/download/v0.1.0%2B7/game.apk")
        self.assertNotIn("latest", binary["url"])
        self.assertEqual(m["artifacts"]["content"]["android"]["sha256"],
                         hashlib.sha256(b"pack bytes").hexdigest())

    def test_no_artifacts_still_lists_both_kinds_empty(self):
        m = self.run_main()
        self.assertEqual(m["artifacts"], {"binary": {}, "content": {}})

    def test_changelog_is_wired_through_main(self):
        changes = self.tmp / "changes.json"
        changes.write_text(json.dumps(["fixed a thing"]), encoding="utf-8")
        previous = self.tmp / "prev.json"
        previous.write_text(json.dumps({"changelog": [entry(6)]}), encoding="utf-8")
        m = self.run_main("--changes-file", str(changes), "--previous-manifest", str(previous))
        self.assertEqual([e["content_version"] for e in m["changelog"]], [7, 6])
        self.assertEqual(m["changelog"][0]["changes"], ["fixed a thing"])


if __name__ == "__main__":
    unittest.main()
