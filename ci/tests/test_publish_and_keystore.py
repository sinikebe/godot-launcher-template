"""Tests for ci/publish_release.sh and ci/setup_keystore.sh.

publish_release.sh is the last step of a release: it decides which assets go up,
whether the release is "latest" or a prerelease (the whole mechanism that keeps a
branch build away from every player on the normal update path), what the notes
and download links say, and whether an existing release is refreshed or created.
setup_keystore.sh decides which key signs the APK; a different key on the next run
makes Android refuse every in-place update.

Both run against a fake gh and a fake keytool that record their arguments, inside a
throwaway git repository, so nothing is published and no secret is real. The fakes
prove what the scripts ASK for; whether GitHub or keytool then does the right thing
is not something these tests can say.

    python3 -B -m unittest discover -s ci/tests -v
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import pathlib
import stat
import subprocess
import unittest

from test_release_scripts import Sandbox

FAKE_GH = """#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_LOG"
prev=""
for arg in "$@"; do
  if [[ "$prev" == --notes-file ]]; then cp "$arg" "$FAKE_GH_NOTES"; fi
  prev="$arg"
done
if [[ "$1 $2" == "release view" ]]; then
  [[ "$FAKE_GH_EXISTS" == 1 ]] && exit 0
  exit 1
fi
[[ "$FAKE_GH_FAIL" == 1 ]] && exit 1
exit 0
"""

FAKE_KEYTOOL = """#!/usr/bin/env bash
echo "$*" >> "$FAKE_KEYTOOL_LOG"
prev=""
for arg in "$@"; do
  if [[ "$prev" == -keystore ]]; then printf 'generated keystore' > "$arg"; fi
  prev="$arg"
done
"""

ASSETS = {
    "launcher-demo.apk": b"apk bytes",
    "LauncherDemo.exe": b"exe bytes",
    "content-android.pck": b"android pack",
    "content-desktop.pck": b"desktop pack",
    "manifest.json": b'{"schema": 1}',
}


class PublishBase(Sandbox):
    def setUp(self):
        super().setUp()
        self.skip_without_gnu_tools()
        self.shell_scripts = ("publish_release.sh", "setup_keystore.sh")
        for name in self.shell_scripts:
            shutil_copy = self.root / "ci" / name
            shutil_copy.write_bytes((self.CI_SRC / name).read_bytes())
        (self.bin / "gh").write_text(FAKE_GH, encoding="utf-8")
        keytool = self.bin / "keytool"
        keytool.write_text(FAKE_KEYTOOL, encoding="utf-8")
        keytool.chmod(0o755)
        self.notes = pathlib.Path(self._dir.name) / "notes.md"
        self.keytool_log = pathlib.Path(self._dir.name) / "keytool.log"
        self.commit("Add the first thing | with a pipe", {"README.md": "x"})
        self.release = self.root / "build" / "release"
        self.release.mkdir(parents=True)
        for name, data in ASSETS.items():
            (self.release / name).write_bytes(data)

    CI_SRC = pathlib.Path(__file__).resolve().parent.parent

    def publish(self, **env):
        base = {
            "TAG": "v0.1.0+3", "VERSION_NAME": "0.1.0", "GAME_NAME": "Launcher Demo",
            "APK_NAME": "launcher-demo.apk", "EXE_NAME": "LauncherDemo.exe",
            "BINARY_VERSION": "7", "CONTENT_VERSION": "3", "GITHUB_REPOSITORY": "me/game",
            "FAKE_GH_NOTES": str(self.notes), "FAKE_GH_EXISTS": "0", "FAKE_GH_FAIL": "0",
        }
        base.update(env)
        return self.run_script("publish_release.sh", **base)

    def gh_calls(self):
        return self.gh_log.read_text(encoding="utf-8").splitlines() if self.gh_log.exists() else []

    def notes_text(self):
        return self.notes.read_text(encoding="utf-8")


class PublishRelease(PublishBase):
    def test_a_normal_release_is_created_as_the_latest_one_with_every_asset(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.gh_calls()
        self.assertEqual(calls[0], "release view v0.1.0+3")
        create = calls[1]
        self.assertTrue(create.startswith("release create v0.1.0+3 "), create)
        for name in list(ASSETS) + ["SHA256SUMS"]:
            self.assertIn("build/release/" + name, create)
        self.assertIn("--title Launcher Demo 0.1.0 ", create + " ")
        self.assertIn("--latest", create)
        self.assertNotIn("--prerelease", create)
        self.assertIn("Published v0.1.0+3: https://github.com/me/game/releases/tag/v0.1.0+3", result.stdout)

    def test_a_branch_build_is_a_prerelease_and_never_latest(self):
        # --prerelease is what keeps /releases/latest/ from ever returning it.
        result = self.publish(TAG="branch-dev", RELEASE_BRANCH="dev")
        self.assertEqual(result.returncode, 0, result.stderr)
        create = self.gh_calls()[1]
        self.assertIn("--prerelease", create)
        self.assertNotIn("--latest", create)
        self.assertIn("--title Launcher Demo 0.1.0 (dev) ", create + " ")

    def test_a_release_is_never_a_draft(self):
        # a draft is invisible to every player's app, and /releases/latest/ skips it
        for env in ({}, {"TAG": "branch-dev", "RELEASE_BRANCH": "dev"}):
            with self.subTest(env=env):
                self.gh_log.unlink(missing_ok=True)
                self.publish(**env)
                self.assertTrue(all("--draft" not in call for call in self.gh_calls()), self.gh_calls())

    def test_an_existing_release_is_refreshed_in_place_not_recreated(self):
        result = self.publish(FAKE_GH_EXISTS="1", TAG="branch-dev", RELEASE_BRANCH="dev")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.gh_calls()
        self.assertEqual([c.split()[1] for c in calls], ["view", "upload", "edit"])
        self.assertIn(" --clobber", calls[1])  # refresh in place: the URL the app polls must not change
        self.assertTrue(calls[1].startswith("release upload branch-dev "))
        for name in list(ASSETS) + ["SHA256SUMS"]:
            self.assertIn("build/release/" + name, calls[1])
        self.assertIn("--title Launcher Demo 0.1.0 (dev) --notes-file", calls[2])
        self.assertIn("--prerelease", calls[2])
        self.assertIn("--notes-file", calls[2])
        self.assertIn("Release branch-dev exists", result.stdout)

    def test_an_existing_normal_release_keeps_its_latest_flag(self):
        self.publish(FAKE_GH_EXISTS="1")
        self.assertIn("--latest", self.gh_calls()[2])
        self.assertNotIn("--prerelease", self.gh_calls()[2])

    def test_a_failing_gh_fails_the_step_and_nothing_is_reported_published(self):
        result = self.publish(FAKE_GH_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Published", result.stdout)

    def test_each_required_variable_is_checked_before_gh_is_called(self):
        for name in ("TAG", "VERSION_NAME", "GAME_NAME", "APK_NAME", "EXE_NAME",
                     "BINARY_VERSION", "CONTENT_VERSION", "GITHUB_REPOSITORY"):
            with self.subTest(missing=name):
                result = self.publish(**{name: ""})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(name + " must be set", result.stderr)
        self.assertEqual(self.gh_calls(), [])

    # -- SHA256SUMS -------------------------------------------------------
    def test_sha256sums_covers_every_asset_exactly_and_not_itself(self):
        self.publish()
        lines = (self.release / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
        want = ["%s  %s" % (hashlib.sha256(data).hexdigest(), name) for name, data in sorted(ASSETS.items())]
        self.assertEqual(lines, want)

    def test_running_it_again_gives_the_same_checksums(self):
        self.publish()
        first = (self.release / "SHA256SUMS").read_bytes()
        self.publish()
        self.assertEqual((self.release / "SHA256SUMS").read_bytes(), first)

    def test_only_the_top_level_files_are_checksummed(self):
        (self.release / "extra").mkdir()
        (self.release / "extra" / "nested.bin").write_bytes(b"nested")
        self.publish()
        names = [line.split("  ", 1)[1] for line in (self.release / "SHA256SUMS").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(names, sorted(ASSETS))

    def test_a_changed_asset_changes_its_checksum(self):
        self.publish()
        (self.release / "manifest.json").write_bytes(b"different")
        self.publish()
        text = (self.release / "SHA256SUMS").read_text(encoding="utf-8")
        self.assertIn(hashlib.sha256(b"different").hexdigest() + "  manifest.json", text)

    def test_the_release_dir_can_be_somewhere_else(self):
        other = self.root / "out"
        other.mkdir()
        (other / "a.bin").write_bytes(b"a")
        self.publish(RELEASE_DIR="out")
        self.assertEqual((other / "SHA256SUMS").read_text(encoding="utf-8").split()[1], "a.bin")
        self.assertIn("out/a.bin", self.gh_calls()[1])

    # -- the notes --------------------------------------------------------
    def test_notes_say_what_was_built(self):
        self.publish()
        text = self.notes_text()
        self.assertIn("## Launcher Demo 0.1.0\n", text)
        self.assertIn("| Binary version | `7` |", text)
        self.assertIn("| Content version | `3` |", text)
        self.assertIn(self.git("rev-parse", "--short=8", "HEAD"), text)
        self.assertIn("Add the first thing | with a pipe", text)

    def test_notes_link_the_assets_through_the_stable_latest_path(self):
        self.publish()
        text = self.notes_text()
        self.assertIn("(https://github.com/me/game/releases/latest/download/launcher-demo.apk)", text)
        self.assertIn("(https://github.com/me/game/releases/latest/download/LauncherDemo.exe)", text)
        self.assertNotIn("Branch build", text)

    def test_a_branch_build_links_through_its_own_tag_never_through_latest(self):
        self.publish(TAG="branch-dev", RELEASE_BRANCH="dev")
        text = self.notes_text()
        self.assertIn("(https://github.com/me/game/releases/download/branch-dev/launcher-demo.apk)", text)
        self.assertNotIn("releases/latest", text)
        self.assertIn("**Branch build", text)
        self.assertIn("| Branch | `dev` |", text)
        self.assertIn("## Launcher Demo 0.1.0 (dev)", text)

    def test_the_debug_key_warning_is_shown_unless_the_key_is_a_release_key(self):
        for kind, warned in (("release", False), ("debug", True), ("", True)):
            with self.subTest(kind=kind):
                self.publish(SIGNING_KIND=kind) if kind else self.publish()
                self.assertEqual("signed with a CI debug key" in self.notes_text(), warned)

    def test_the_whats_new_section_lists_the_notes(self):
        notes = self.root / "build" / "notes"
        notes.mkdir(parents=True)
        (notes / "changes.json").write_text(json.dumps(["Fixed a thing", "Added é — another"]), encoding="utf-8")
        self.publish()
        text = self.notes_text()
        self.assertIn("### What's new\n\n- Fixed a thing\n- Added é — another\n", text)

    def test_no_notes_means_no_whats_new_section(self):
        self.publish()
        self.assertNotIn("What's new", self.notes_text())
        notes = self.root / "build" / "notes"
        notes.mkdir(parents=True)
        (notes / "changes.json").write_text("", encoding="utf-8")
        self.publish()
        self.assertNotIn("What's new", self.notes_text())

    def test_unreadable_notes_do_not_stop_the_release(self):
        notes = self.root / "build" / "notes"
        notes.mkdir(parents=True)
        (notes / "changes.json").write_text("{not json", encoding="utf-8")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.gh_calls()[1].startswith("release create"))


class SetupKeystore(PublishBase):
    def setUp(self):
        super().setUp()
        self.temp = pathlib.Path(self._dir.name) / "runner_temp"
        self.cache = pathlib.Path(self._dir.name) / "cache"
        self.output = pathlib.Path(self._dir.name) / "gh_output"
        self.summary = pathlib.Path(self._dir.name) / "summary.md"

    def keystore(self, **env):
        base = {"RUNNER_TEMP": str(self.temp), "KEYSTORE_CACHE_DIR": str(self.cache),
                "GITHUB_OUTPUT": str(self.output), "GITHUB_STEP_SUMMARY": str(self.summary),
                "FAKE_KEYTOOL_LOG": str(self.keytool_log)}
        base.update(env)
        return self.run_script("setup_keystore.sh", **base)

    def outputs(self):
        return dict(line.split("=", 1) for line in self.output.read_text(encoding="utf-8").splitlines())

    @property
    def path(self):
        return self.temp / "launcher-signing" / "android.keystore"

    def mode(self, path):
        return stat.S_IMODE(os.stat(path).st_mode)

    def test_a_release_keystore_is_decoded_to_a_private_file_outside_the_workspace(self):
        secret = base64.b64encode(b"real keystore bytes").decode()
        result = self.keystore(ANDROID_KEYSTORE_BASE64=secret)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_bytes(), b"real keystore bytes")
        self.assertEqual(self.mode(self.path), 0o600)
        self.assertEqual(self.mode(self.path.parent), 0o700)
        self.assertEqual(self.outputs(), {"kind": "release", "path": str(self.path)})
        self.assertFalse(self.keytool_log.exists(), "a configured key must never trigger key generation")
        self.assertNotIn(str(self.root), str(self.path))

    def test_the_secret_is_never_printed(self):
        secret = base64.b64encode(b"super secret keystore bytes").decode()
        result = self.keystore(ANDROID_KEYSTORE_BASE64=secret)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertNotIn(secret, self.output.read_text(encoding="utf-8"))

    def test_a_secret_that_decodes_to_nothing_is_an_error(self):
        result = self.keystore(ANDROID_KEYSTORE_BASE64="\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists() and "kind=" in self.output.read_text(encoding="utf-8"))

    def test_a_secret_that_is_not_base64_is_an_error(self):
        result = self.keystore(ANDROID_KEYSTORE_BASE64="!!!not base64!!!")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists() and "kind=" in self.output.read_text(encoding="utf-8"))

    def test_without_a_secret_a_debug_key_is_generated_once_and_then_reused(self):
        first = self.keystore(GAME_NAME="My Game")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(self.path.read_bytes(), b"generated keystore")
        self.assertEqual(self.mode(self.path), 0o600)
        self.assertEqual(self.outputs(), {"kind": "debug", "path": str(self.path)})
        args = self.keytool_log.read_text(encoding="utf-8")
        for want in ("-genkeypair", "-alias androiddebugkey", "-storepass android", "-keypass android",
                     "-keyalg RSA", "-keysize 2048", "-validity 10950", "-noprompt",
                     "-dname CN=My Game Debug, OU=CI, O=My Game, L=, S=, C=US"):
            self.assertIn(want, args)
        self.assertEqual((self.cache / "debug.keystore").read_bytes(), b"generated keystore")

        self.output.unlink()
        self.path.unlink()
        second = self.keystore(GAME_NAME="My Game")
        self.assertIn("Reusing the cached debug keystore", second.stdout)
        self.assertEqual(self.path.read_bytes(), b"generated keystore")
        self.assertEqual(len(self.keytool_log.read_text(encoding="utf-8").splitlines()), 1,
                         "the signature must stay the same: keytool may only run once")

    def test_a_cached_key_is_used_byte_for_byte(self):
        self.cache.mkdir()
        (self.cache / "debug.keystore").write_bytes(b"restored from the actions cache")
        result = self.keystore()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_bytes(), b"restored from the actions cache")
        self.assertFalse(self.keytool_log.exists())

    def test_an_empty_cached_key_is_not_trusted(self):
        self.cache.mkdir()
        (self.cache / "debug.keystore").write_bytes(b"")
        self.keystore()
        self.assertEqual(self.path.read_bytes(), b"generated keystore")

    def test_the_game_name_defaults_in_the_certificate(self):
        self.keystore()
        self.assertIn("-dname CN=Game Debug, OU=CI, O=Game,", self.keytool_log.read_text(encoding="utf-8"))

    def test_the_debug_key_fallback_leaves_a_warning_in_the_job_summary(self):
        self.keystore()
        text = self.summary.read_text(encoding="utf-8")
        self.assertIn("throwaway debug key", text)
        self.assertIn("ANDROID_KEYSTORE_BASE64", text)

    def test_the_job_summary_is_appended_to_not_overwritten(self):
        self.summary.write_text("written by an earlier step\n", encoding="utf-8")
        self.keystore()
        text = self.summary.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("written by an earlier step\n"))
        self.assertIn("throwaway debug key", text)

    def test_the_debug_key_is_cached_under_the_default_directory_when_none_is_given(self):
        result = self.run_script("setup_keystore.sh", RUNNER_TEMP=str(self.temp), GITHUB_OUTPUT=str(self.output),
                                 GITHUB_STEP_SUMMARY=str(self.summary), FAKE_KEYTOOL_LOG=str(self.keytool_log))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        cached = self.temp / "launcher-keystore-cache" / "debug.keystore"
        self.assertTrue(cached.exists(), sorted(str(p) for p in self.temp.rglob("*")))
        self.assertEqual(cached.read_bytes(), b"generated keystore")

    def test_a_release_key_leaves_no_debug_warning(self):
        self.keystore(ANDROID_KEYSTORE_BASE64=base64.b64encode(b"k").decode())
        self.assertFalse(self.summary.exists())

    def test_the_output_file_is_appended_to(self):
        self.output.write_text("earlier=step\n", encoding="utf-8")
        self.keystore()
        self.assertEqual(self.output.read_text(encoding="utf-8").splitlines()[0], "earlier=step")

    def test_a_missing_keytool_is_an_error_not_a_silent_unsigned_build(self):
        (self.bin / "keytool").unlink()
        result = self.run_script("setup_keystore.sh", RUNNER_TEMP=str(self.temp), KEYSTORE_CACHE_DIR=str(self.cache),
                                 GITHUB_OUTPUT=str(self.output), PATH="/usr/bin:/bin")
        if subprocess.run(["bash", "-c", "command -v keytool"], capture_output=True,
                          env={"PATH": "/usr/bin:/bin"}).returncode == 0:
            self.skipTest("a real keytool is installed")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists() and "kind=" in self.output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
