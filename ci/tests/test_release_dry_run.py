"""Tests for ci/release_dry_run.sh, the pull-request rehearsal of the end of release.yml.

The rehearsal runs the "Assemble release directory" and "Build update manifest"
steps of the real .github/workflows/release.yml, then checks the result and runs
publish_release.sh against a stand-in for gh. These tests check that it passes on a
healthy build, that it fails when a step of the release path is broken, that it copes
with a game that customises release.yml, and that ci.yml and release.yml still agree
about what is exported.

    python3 -B -m unittest discover -s ci/tests -v
"""

from __future__ import annotations

import json
import pathlib
import re
import shutil
import unittest

from test_release_scripts import Sandbox

REPO = pathlib.Path(__file__).resolve().parent.parent.parent

ENV = {
    "TAG": "v0.1.0+3", "VERSION_NAME": "0.1.0", "GAME_NAME": "Launcher Demo",
    "APK_NAME": "launcher-demo.apk", "EXE_NAME": "LauncherDemo.exe",
    "BINARY_VERSION": "7", "CONTENT_VERSION": "3", "COMMIT": "abcdef12",
    "GITHUB_REPOSITORY": "me/game",
}

ASSEMBLE_EXE = "cp build/windows/${{ steps.version.outputs.exe_name }} build/release/\n"
MANIFEST_MACOS = '            --artifact "content:macos:build/release/content-desktop.pck" \\\n'


class Rehearsal(Sandbox):
    SCRIPTS = ("release_dry_run.sh", "publish_release.sh", "make_manifest.py")

    def setUp(self):
        super().setUp()
        self.commit("Add the first thing", {"README.md": "x"})
        self.commit("Fix the second thing")
        workflows = self.root / ".github" / "workflows"
        workflows.mkdir(parents=True)
        shutil.copy(REPO / ".github" / "workflows" / "release.yml", workflows / "release.yml")
        for path, data in {
            "build/android/launcher-demo.apk": b"apk bytes",
            "build/windows/LauncherDemo.exe": b"exe bytes",
            "build/content/content-android.pck": b"android pack",
            "build/content/content-desktop.pck": b"desktop pack",
        }.items():
            full = self.root / path
            full.parent.mkdir(parents=True, exist_ok=True)
            full.write_bytes(data)
        notes = self.root / "build" / "notes"
        notes.mkdir(parents=True)
        (notes / "changes.json").write_text(json.dumps(["Fix the second thing", "Add the first thing"]), encoding="utf-8")
        self.out = self.root / "build" / "release"

    def rehearse(self, **env):
        merged = dict(ENV)
        merged.update(env)
        return self.run_script("release_dry_run.sh", **merged)

    def break_file(self, relative, old, new):
        path = self.root / relative
        text = path.read_text(encoding="utf-8")
        self.assertEqual(text.count(old), 1, old)
        path.write_text(text.replace(old, new), encoding="utf-8")

    def break_workflow(self, old, new):
        self.break_file(".github/workflows/release.yml", old, new)

    # -- a healthy build passes -------------------------------------------
    def test_a_healthy_build_passes_and_publishes_nothing(self):
        result = self.rehearse()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--- release.yml step: Assemble release directory ---", result.stdout)
        self.assertIn("--- release.yml step: Build update manifest ---", result.stdout)
        self.assertIn("manifest.json is consistent with the 6 artifact entries", result.stdout)
        self.assertIn("asked for a latest release with 6 assets", result.stdout)
        self.assertIn("Release rehearsal passed for v0.1.0+3: nothing was published.", result.stdout)
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), sorted([
            "LauncherDemo.exe", "SHA256SUMS", "content-android.pck", "content-desktop.pck",
            "launcher-demo.apk", "manifest.json"]))
        self.assertFalse(self.gh_log.exists(), "the real gh must never be reached")

    def test_publish_output_is_marked_so_it_cannot_be_read_as_a_real_publish(self):
        result = self.rehearse()
        self.assertIn("nothing below was published", result.stdout)
        published = [line for line in result.stdout.splitlines() if "Published v0.1.0+3" in line]
        self.assertEqual(len(published), 1)
        self.assertTrue(published[0].startswith("    | "), published[0])

    def test_the_manifest_it_builds_is_the_one_the_app_reads(self):
        self.rehearse()
        manifest = json.loads((self.out / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(sorted(manifest["artifacts"]["binary"]), ["android", "windows"])
        self.assertEqual(sorted(manifest["artifacts"]["content"]), ["android", "linux", "macos", "windows"])
        self.assertEqual(manifest["release_tag"], "v0.1.0+3")

    def test_a_branch_build_is_rehearsed_as_a_prerelease(self):
        result = self.rehearse(TAG="branch-dev", RELEASE_BRANCH="dev")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("asked for a prerelease release with 6 assets", result.stdout)

    def test_a_stale_output_directory_is_cleared_first(self):
        self.out.mkdir(parents=True)
        (self.out / "left-over.bin").write_bytes(b"old")
        result = self.rehearse()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.out / "left-over.bin").exists())

    def test_it_can_be_run_twice(self):
        self.assertEqual(self.rehearse().returncode, 0)
        self.assertEqual(self.rehearse().returncode, 0)

    # -- a game that customises release.yml is rehearsed as it is ---------
    def test_a_game_that_publishes_more_is_still_checked_and_passes(self):
        (self.root / "build" / "linux").mkdir()
        (self.root / "build" / "linux" / "game.x86_64").write_bytes(b"linux binary")
        self.break_workflow(ASSEMBLE_EXE, ASSEMBLE_EXE + "          cp build/linux/game.x86_64 build/release/\n")
        self.break_workflow(MANIFEST_MACOS, MANIFEST_MACOS + '            --artifact "binary:linux:build/release/game.x86_64" \\\n')
        result = self.rehearse()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("with the 7 artifact entries", result.stdout.replace("manifest.json is consistent ", ""))
        self.assertIn("with 7 assets", result.stdout)

    def test_an_extra_entry_with_a_wrong_hash_is_caught_too(self):
        (self.root / "build" / "linux").mkdir()
        (self.root / "build" / "linux" / "game.x86_64").write_bytes(b"linux binary")
        self.break_workflow(ASSEMBLE_EXE, ASSEMBLE_EXE + "          cp build/linux/game.x86_64 build/release/\n")
        self.break_workflow(MANIFEST_MACOS, MANIFEST_MACOS + '            --artifact "binary:linux:build/release/game.x86_64" \\\n')
        self.break_file("ci/make_manifest.py", "digest.update(chunk)", "digest.update(chunk[:-1])")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("binary:linux sha256 does not match", result.stderr)

    # -- a broken release path fails --------------------------------------
    def test_a_missing_export_fails_and_is_named(self):
        for path in ("build/android/launcher-demo.apk", "build/windows/LauncherDemo.exe",
                     "build/content/content-android.pck", "build/content/content-desktop.pck"):
            with self.subTest(path=path):
                full = self.root / path
                original = full.read_bytes()
                full.unlink()
                result = self.rehearse()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(path, result.stderr)
                full.write_bytes(original)

    def test_an_empty_export_fails_and_is_named(self):
        sources = {"launcher-demo.apk": "build/android", "LauncherDemo.exe": "build/windows",
                   "content-android.pck": "build/content", "content-desktop.pck": "build/content"}
        for name, folder in sources.items():
            with self.subTest(name=name):
                path = self.root / folder / name
                original = path.read_bytes()
                self.assertTrue(original, "the fixture itself must not be empty")
                path.write_bytes(b"")
                result = self.rehearse()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("would be published empty", result.stderr)
                self.assertIn(name, result.stderr)
                path.write_bytes(original)

    def test_each_required_variable_is_checked(self):
        for name in ENV:
            with self.subTest(missing=name):
                result = self.rehearse(**{name: ""})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name + " must be set", result.stderr)

    def test_a_manifest_with_the_wrong_hash_fails_the_check(self):
        self.break_file("ci/make_manifest.py", "digest.update(chunk)", "digest.update(chunk[:-1])")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest check:", result.stderr)
        self.assertIn("sha256 does not match", result.stderr)

    def test_a_manifest_url_that_is_not_pinned_to_the_tag_fails_the_check(self):
        self.break_file("ci/make_manifest.py", "releases/download/", "releases/latest/download/")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("url is", result.stderr)

    def test_a_manifest_for_another_tag_fails_the_check(self):
        self.break_file("ci/make_manifest.py", '"release_tag": args.tag', '"release_tag": "v9.9.9+9"')
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release_tag is", result.stderr)

    def test_a_wrong_size_fails_the_check(self):
        self.break_file("ci/make_manifest.py", '"size": path.stat().st_size', '"size": path.stat().st_size + 1')
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("size does not match", result.stderr)

    def test_a_platform_the_updater_asks_for_must_be_in_the_manifest(self):
        self.break_workflow(MANIFEST_MACOS, "")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("content:macos is missing from the manifest", result.stderr)

    def test_the_binaries_must_be_listed_under_the_names_the_app_downloads(self):
        self.break_workflow('--artifact "binary:windows:build/release/${{ steps.version.outputs.exe_name }}"',
                            '--artifact "binary:windows:build/release/${{ steps.version.outputs.apk_name }}"')
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("binary:windows names file", result.stderr)

    def test_an_empty_changelog_fails_the_check(self):
        self.break_file("ci/make_manifest.py", "return [entry] + history[: MAX_CHANGELOG_ENTRIES - 1]", "return []")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changelog is empty", result.stderr)

    def test_a_changelog_whose_newest_entry_is_not_this_build_fails_the_check(self):
        self.break_file("ci/make_manifest.py", "return [entry] + history[: MAX_CHANGELOG_ENTRIES - 1]",
                        "return [dict(entry, content_version=99)]")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the newest changelog entry is not this build", result.stderr)

    def test_a_publish_script_that_stops_marking_the_release_latest_fails_the_check(self):
        self.break_file("ci/publish_release.sh", "RELEASE_FLAGS=(--latest)", "RELEASE_FLAGS=()")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("publish check:", result.stderr)

    def test_a_branch_build_that_would_become_latest_fails_the_check(self):
        self.break_file("ci/publish_release.sh", "RELEASE_FLAGS=(--prerelease)", "RELEASE_FLAGS=(--prerelease --latest)")
        result = self.rehearse(TAG="branch-dev", RELEASE_BRANCH="dev")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("never latest", result.stderr)

    def test_an_asset_the_publish_script_would_leave_out_fails_the_check(self):
        self.break_file("ci/publish_release.sh", 'gh release create "$TAG" "$RELEASE_DIR"/* \\', 'gh release create "$TAG" "$RELEASE_DIR"/*.apk \\')
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not among the uploaded assets", result.stderr)

    def test_notes_that_link_the_wrong_place_fail_the_check(self):
        self.break_file("ci/publish_release.sh", 'releases/latest/download"', 'releases/download/oops"')
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the release notes do not link", result.stderr)

    def test_a_publish_script_that_fails_fails_the_rehearsal(self):
        self.break_file("ci/publish_release.sh", ': "${TAG:?TAG must be set}"', "exit 3")
        self.assertNotEqual(self.rehearse().returncode, 0)

    # -- the workflow cannot be read: say so, loudly ----------------------
    def test_a_missing_step_is_named(self):
        self.break_workflow("- name: Build update manifest", "- name: Something else")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no step named 'Build update manifest'", result.stderr)

    def test_a_step_without_a_run_block_is_reported(self):
        self.break_workflow("- name: Assemble release directory\n        run: |", "- name: Assemble release directory\n        run: echo")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no 'run: |' block", result.stderr)

    def test_an_expression_it_cannot_resolve_is_reported_and_nothing_runs(self):
        self.break_workflow(ASSEMBLE_EXE, ASSEMBLE_EXE + "          echo ${{ github.token }}\n")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("uses an expression the rehearsal cannot resolve", result.stderr)
        self.assertIn("github.token", result.stderr)
        self.assertFalse(self.out.exists() and any(self.out.iterdir()))

    def test_an_output_the_ci_step_does_not_pass_stops_the_rehearsal(self):
        self.break_workflow(ASSEMBLE_EXE, ASSEMBLE_EXE + "          echo ${{ steps.version.outputs.game_slug }}\n")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GAME_SLUG", result.stderr)

    def test_an_assemble_step_that_creates_no_release_directory_is_reported(self):
        path = self.root / ".github" / "workflows" / "release.yml"
        text = path.read_text(encoding="utf-8")
        start = text.index("- name: Assemble release directory")
        end = text.index("\n      - name:", start)
        path.write_text(text[:start] + "- name: Assemble release directory\n        run: |\n          echo nothing\n" + text[end:],
                        encoding="utf-8")
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the assemble step did not create build/release", result.stderr)

    def test_a_manifest_entry_for_a_file_that_is_not_in_the_release_directory_fails_the_check(self):
        (self.root / "build" / "extra").mkdir()
        (self.root / "build" / "extra" / "extra.pck").write_bytes(b"never copied")
        self.break_workflow(MANIFEST_MACOS, MANIFEST_MACOS + '            --artifact "content:ios:build/extra/extra.pck" \\\n')
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("content:ios names 'extra.pck', which is not in the release directory", result.stderr)

    def test_a_missing_workflow_file_is_reported(self):
        (self.root / ".github" / "workflows" / "release.yml").unlink()
        result = self.rehearse()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot read", result.stderr)


class KeepInStep(unittest.TestCase):
    """ci.yml must export what release.yml publishes, and hand the rehearsal what it reads."""

    release = (REPO / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
    ci = (REPO / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")

    @staticmethod
    def normalise(text):
        text = re.sub(r"\$\{\{ steps\.version\.outputs\.(\w+) \}\}", lambda m: "$" + m.group(1).upper(), text)
        return re.sub(r"\$\{(\w+)\}", r"$\1", text)

    def step(self, text, name):
        match = re.search(r"- name: %s\n(.*?)(?=\n      - name: |\Z)" % re.escape(name), text, re.S)
        self.assertIsNotNone(match, "no step named %r" % name)
        return match.group(1)

    def test_every_file_release_yml_collects_is_one_ci_yml_exports(self):
        collected = re.findall(r"cp (build/\S+) build/release/", self.normalise(self.step(self.release, "Assemble release directory")))
        self.assertGreaterEqual(len(collected), 4)
        exports = self.normalise(self.step(self.ci, "Export Android APK") + self.step(self.ci, "Export Windows executable")
                                 + self.step(self.ci, "Export content packs"))
        for path in collected:
            self.assertIn(path, exports, "release.yml collects %s but ci.yml's export steps do not produce it" % path)

    def test_ci_passes_every_output_the_extracted_steps_read(self):
        rehearsal = self.step(self.ci, "Rehearse the release assembly and publish script")
        used = set()
        for name in ("Assemble release directory", "Build update manifest"):
            used |= set(re.findall(r"\$\{\{ steps\.version\.outputs\.(\w+) \}\}", self.step(self.release, name)))
        self.assertGreaterEqual(len(used), 6)
        for name in used:
            self.assertRegex(rehearsal, r"\n          %s: \$\{\{ steps\.version\.outputs\.%s \}\}" % (name.upper(), name))

    def test_ci_runs_the_rehearsal_after_the_exports(self):
        step = self.step(self.ci, "Rehearse the release assembly and publish script")
        self.assertIn("run: bash ci/release_dry_run.sh", step)
        self.assertLess(self.ci.index("- name: Export content packs"),
                        self.ci.index("- name: Rehearse the release assembly"))

    def test_the_publish_step_of_the_real_workflow_passes_what_publish_release_reads(self):
        real = self.step(self.release, "Publish release")
        for name in ("TAG", "VERSION_NAME", "GAME_NAME", "APK_NAME", "EXE_NAME", "BINARY_VERSION", "CONTENT_VERSION"):
            self.assertIn(name + ": ", real)
        self.assertIn("bash ci/publish_release.sh", real)


if __name__ == "__main__":
    unittest.main()
