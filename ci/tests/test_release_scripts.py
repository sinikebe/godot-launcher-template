"""Tests for ci/collect_changes.sh and ci/prepare_build.sh, the release steps that
run before anything is exported: they decide the version a build carries, the tag
it is published under, which patch notes ship, and (for a branch build) which app
and which user:// it is. A mistake in either ships a build that updates wrongly or
overwrites the player's real app, and no export is needed to see it.

Each test builds a throwaway git repository, copies the scripts into its ci/, and
runs them with bash, so nothing here touches this checkout. Standard library only:

    python3 -B -m unittest discover -s ci/tests -v

Needs bash 4 (mapfile) and git, as the scripts do.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

CI_DIR = pathlib.Path(__file__).resolve().parent.parent

# binary_version differs from every commit count the tests reach, so a script that
# stamps one where it means the other cannot pass by coincidence.
VERSION_JSON = {"game_name": "Launcher Demo", "version_name": "0.1.0", "binary_version": 7}

PRESETS = """[preset.0]

name="Android"
platform="Android"

[preset.0.options]

version/code=1
version/name="0.0.0"
package/unique_name="com.example.game"
package/name="Game"

[preset.1]

name="Windows Desktop"
platform="Windows Desktop"

[preset.1.options]

application/product_name="Game"
application/file_description="Game"
"""

PROJECT = """config_version=5

[application]

config/name="Launcher Demo"
run/main_scene="res://main.tscn"

[display]

window/size/viewport_width=1280
"""

FAKE_GH = """#!/usr/bin/env bash
echo "$@" >> "$FAKE_GH_LOG"
if [[ "$FAKE_GH_MODE" == ok ]]; then
  out=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == --output ]] && out="$2"
    shift
  done
  printf '{"changelog": []}' > "$out"
  exit 0
fi
exit 1
"""


class Sandbox(unittest.TestCase):
    """A scratch repo with the release scripts in ci/."""

    def setUp(self):
        if shutil.which("git") is None or shutil.which("bash") is None or shutil.which("python3") is None:
            self.skipTest("needs git, bash and python3")
        bash_major = subprocess.run(["bash", "-c", "echo $BASH_VERSINFO"], capture_output=True, text=True).stdout.strip()
        if not bash_major.isdigit() or int(bash_major) < 4:
            self.skipTest("the scripts need bash 4 (mapfile); this is bash %s" % (bash_major or "?"))
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.root = pathlib.Path(self._dir.name) / "repo"
        (self.root / "ci").mkdir(parents=True)
        for name in ("collect_changes.sh", "prepare_build.sh"):
            shutil.copy(CI_DIR / name, self.root / "ci" / name)
        self.bin = pathlib.Path(self._dir.name) / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)
        self.gh_log = pathlib.Path(self._dir.name) / "gh.log"
        self.home = pathlib.Path(self._dir.name) / "home"
        self.home.mkdir()
        self.git("init", "-q")
        self.git("config", "commit.gpgsign", "false")

    # -- plumbing ---------------------------------------------------------
    def env(self, **extra):
        env = {
            "PATH": "%s:%s" % (self.bin, os.environ.get("PATH", "/usr/bin:/bin")),
            "HOME": str(self.home),
            "LANG": "C.UTF-8",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
            "FAKE_GH_LOG": str(self.gh_log),
            "FAKE_GH_MODE": "fail",
        }
        env.update(extra)
        return env

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env(), check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, message="work", files=None):
        for name, text in (files or {}).items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)

    def run_script(self, script, **env):
        return subprocess.run(["bash", str(self.root / "ci" / script)], cwd=self.root,
                              env=self.env(**env), capture_output=True, text=True)

    def read(self, name):
        return (self.root / name).read_text(encoding="utf-8")


class CollectChanges(Sandbox):
    def changes(self):
        return json.loads(self.read("build/notes/changes.json"))

    def test_no_tag_describes_the_whole_history_newest_first(self):
        for subject in ("first", "second", "third"):
            self.commit(subject)
        result = self.run_script("collect_changes.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.changes(), ["third", "second", "first"])
        self.assertIn("No previous release found", result.stdout)

    def test_only_commits_since_the_latest_release_tag(self):
        self.commit("old")
        self.git("tag", "v0.1.0+1")
        self.commit("new one")
        self.commit("new two")
        result = self.run_script("collect_changes.sh")
        self.assertEqual(self.changes(), ["new two", "new one"])
        self.assertIn("Previous release: v0.1.0+1", result.stdout)

    def test_the_previous_release_is_the_highest_number_not_the_last_alphabetically(self):
        self.commit("a")
        self.git("tag", "v0.1.0+9")
        self.commit("b")
        self.git("tag", "v0.1.0+10")
        self.commit("c")
        result = self.run_script("collect_changes.sh")
        self.assertIn("Previous release: v0.1.0+10", result.stdout)
        self.assertEqual(self.changes(), ["c"])

    def test_tags_that_are_not_release_tags_are_ignored(self):
        self.commit("a")
        self.git("tag", "v0.1.0+3")
        self.commit("b")
        # "v1+9+3" and "v1+12abc" would win a numeric sort if the filter let them through
        for tag in ("branch-dev", "v1+abc", "v1+2+3", "vfoo", "v0.9.9", "rc+99", "nightly+100", "v1+9+3", "v1+12abc"):
            self.git("tag", tag)
        self.commit("c")
        result = self.run_script("collect_changes.sh")
        self.assertIn("Previous release: v0.1.0+3", result.stdout)
        self.assertEqual(self.changes(), ["c", "b"])

    def test_housekeeping_commits_are_left_out_of_player_notes(self):
        for subject in ("Bump version", "chore: tidy", "ci: pin", "WIP half", "Merge branch x",
                        "Revert \"y\"", "Fix the thing", "Add the other thing"):
            self.commit(subject)
        self.run_script("collect_changes.sh")
        self.assertEqual(self.changes(), ["Add the other thing", "Fix the thing"])

    def test_noise_is_matched_at_the_start_only(self):
        self.commit("Add a chore wheel")
        self.commit("Stop the ci: prefix leaking")
        self.run_script("collect_changes.sh")
        self.assertEqual(self.changes(), ["Stop the ci: prefix leaking", "Add a chore wheel"])

    def test_real_merge_commits_do_not_appear(self):
        self.commit("base")
        main = self.git("branch", "--show-current")
        self.git("checkout", "-q", "-b", "side")
        self.commit("from the side")
        self.git("checkout", "-q", main)
        self.commit("on main")
        self.git("merge", "-q", "--no-ff", "-m", "Join the side", "side")
        self.run_script("collect_changes.sh")
        self.assertEqual(sorted(self.changes()), ["base", "from the side", "on main"])

    def test_nothing_new_since_the_tag_is_an_empty_list(self):
        self.commit("a")
        self.git("tag", "v0.1.0+1")
        result = self.run_script("collect_changes.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.changes(), [])

    def test_non_ascii_subjects_survive(self):
        self.commit("Corrige l'écran de démarrage — vite")
        self.run_script("collect_changes.sh")
        self.assertEqual(self.changes(), ["Corrige l'écran de démarrage — vite"])

    def test_without_a_token_the_previous_manifest_is_not_fetched(self):
        self.commit("a")
        self.git("tag", "v0.1.0+1")
        self.commit("b")
        self.run_script("collect_changes.sh", FAKE_GH_MODE="ok")
        self.assertFalse((self.root / "build/notes/previous.json").exists())
        self.assertFalse(self.gh_log.exists())

    def test_with_a_token_the_previous_manifest_is_carried_forward(self):
        self.commit("a")
        self.git("tag", "v0.1.0+1")
        self.commit("b")
        result = self.run_script("collect_changes.sh", GH_TOKEN="x", FAKE_GH_MODE="ok")
        self.assertEqual(json.loads(self.read("build/notes/previous.json")), {"changelog": []})
        self.assertIn("release download v0.1.0+1 --pattern manifest.json", self.gh_log.read_text())
        self.assertIn("Carried forward", result.stdout)

    def test_a_failed_download_does_not_fail_the_build(self):
        self.commit("a")
        self.git("tag", "v0.1.0+1")
        self.commit("b")
        result = self.run_script("collect_changes.sh", GITHUB_TOKEN="x", FAKE_GH_MODE="fail")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "build/notes/previous.json").exists())
        self.assertIn("No previous manifest to carry forward", result.stdout)
        self.assertEqual(self.changes(), ["b"])

    def test_the_first_release_never_calls_gh(self):
        self.commit("a")
        self.run_script("collect_changes.sh", GH_TOKEN="x", FAKE_GH_MODE="ok")
        self.assertFalse(self.gh_log.exists())


class PrepareHelpers(Sandbox):
    """Repo with a committed game and the helpers prepare_build.sh tests share (no tests of its own)."""

    def setUp(self):
        super().setUp()
        self.files = {
            "version.json": json.dumps(VERSION_JSON),
            "export_presets.cfg": PRESETS,
            "project.godot": PROJECT,
            "build_version.gd": "const BINARY_VERSION: int = 0\n",
        }
        self.commit("one", self.files)
        self.commit("two")

    def prepare(self, **env):
        result = self.run_script("prepare_build.sh", **env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines()
                    if re.match(r"^[a-z_]+=", line))

    def const(self, name):
        match = re.search(r"^const %s(?:: \w+)? :?= (.*)$" % name, self.read("build_version.gd"), re.M)
        self.assertIsNotNone(match, name)
        return match.group(1)

    def write_notes(self, text):
        path = self.root / "build/notes"
        path.mkdir(parents=True, exist_ok=True)
        (path / "changes.json").write_text(text, encoding="utf-8")

    def changes_literal(self):
        return json.loads(re.search(r"^const CHANGES := (.*)$", self.read("build_version.gd"), re.M).group(1))


class PrepareBuild(PrepareHelpers):
    # -- the stamp --------------------------------------------------------
    def test_build_version_carries_what_the_app_compares(self):
        out = self.prepare()
        self.assertEqual(self.const("BINARY_VERSION"), "7")
        self.assertEqual(self.const("CONTENT_VERSION"), "2")  # two commits
        self.assertEqual(self.const("VERSION_NAME"), '"0.1.0"')
        self.assertEqual(self.const("COMMIT"), '"%s"' % self.git("rev-parse", "--short=8", "HEAD"))
        self.assertEqual(self.const("IS_CI_BUILD"), "false")
        self.assertEqual(self.const("RELEASE_BRANCH"), '""')
        self.assertTrue(re.fullmatch(r'"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"', self.const("BUILT_AT")))
        self.assertEqual(out["content_version"], "2")
        self.assertEqual(out["binary_version"], "7")
        self.assertEqual(out["tag"], "v0.1.0+2")
        self.assertEqual(out["release_branch"], "")

    def test_content_version_moves_with_every_commit(self):
        self.prepare()
        first = int(self.const("CONTENT_VERSION"))
        self.commit("three")
        self.prepare()
        self.assertEqual(int(self.const("CONTENT_VERSION")), first + 1)

    def test_a_ci_run_says_so(self):
        self.prepare(GITHUB_ACTIONS="true")
        self.assertEqual(self.const("IS_CI_BUILD"), "true")

    def test_android_version_code_follows_content_not_binary(self):
        self.prepare()
        presets = self.read("export_presets.cfg")
        self.assertIn("version/code=2\n", presets)
        self.assertNotIn("version/code=7", presets)
        self.assertIn('version/name="0.1.0"\n', presets)
        self.assertNotIn("version/code=1", presets)

    def test_a_project_without_export_presets_still_gets_a_stamp(self):
        (self.root / "export_presets.cfg").unlink()
        self.git("rm", "-q", "--cached", "export_presets.cfg")
        self.git("commit", "-q", "-m", "drop presets")
        result = self.run_script("prepare_build.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No export_presets.cfg", result.stdout)
        self.assertEqual(self.const("BINARY_VERSION"), "7")

    # -- names ------------------------------------------------------------
    def test_artifact_names_come_from_the_game_name(self):
        out = self.prepare()
        self.assertEqual((out["game_name"], out["apk_name"], out["exe_name"]),
                         ("Launcher Demo", "launcher-demo.apk", "LauncherDemo.exe"))

    def test_artifact_names_are_made_safe(self):
        self.commit("rename", {"version.json": json.dumps(dict(VERSION_JSON, game_name="  Mon Jeu: l'été!  "))})
        out = self.prepare()
        self.assertEqual(out["game_name"], "Mon Jeu: l'été!")
        self.assertEqual(out["apk_name"], "mon-jeu-l-t.apk")
        self.assertEqual(out["exe_name"], "MonJeult.exe")

    def test_a_missing_or_blank_game_name_falls_back(self):
        for name in ("", "   ", "!!!"):
            with self.subTest(name=name):
                self.commit("rename", {"version.json": json.dumps(dict(VERSION_JSON, game_name=name))})
                out = self.prepare()
                self.assertEqual((out["apk_name"], out["exe_name"]), ("game.apk", "Game.exe"))
        self.commit("no name", {"version.json": json.dumps({"version_name": "0.1.0", "binary_version": 2})})
        self.assertEqual(self.prepare()["game_name"], "Game")

    # -- patch notes ------------------------------------------------------
    def test_notes_are_baked_in_capped_and_quoted(self):
        items = ['Fixé "le" bug', "back\\slash", "ligne"] + ["n%d" % i for i in range(30)]
        self.write_notes(json.dumps(items))
        self.prepare()
        self.assertEqual(self.changes_literal(), items[:20])

    def test_no_notes_or_broken_notes_mean_an_empty_list(self):
        self.prepare()
        self.assertEqual(self.changes_literal(), [])
        self.write_notes("{not json")
        self.prepare()
        self.assertEqual(self.changes_literal(), [])

    # -- GITHUB_OUTPUT ----------------------------------------------------
    def test_github_output_gets_every_value_the_workflow_reads(self):
        target = pathlib.Path(self._dir.name) / "gh_output"
        self.prepare(GITHUB_OUTPUT=str(target))
        got = dict(line.split("=", 1) for line in target.read_text(encoding="utf-8").splitlines())
        self.assertEqual(sorted(got), sorted([
            "game_name", "game_slug", "apk_name", "exe_name", "version_name", "binary_version",
            "content_version", "commit", "built_at", "release_branch", "tag"]))
        self.assertEqual(got["game_slug"], "launcher-demo")
        self.assertEqual(got["binary_version"], "7")
        self.assertEqual(got["tag"], "v0.1.0+2")
        built_at = got.pop("built_at")
        self.assertRegex(built_at, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(got, {
            "game_name": "Launcher Demo", "game_slug": "launcher-demo", "apk_name": "launcher-demo.apk",
            "exe_name": "LauncherDemo.exe", "version_name": "0.1.0", "binary_version": "7",
            "content_version": "2", "commit": self.git("rev-parse", "--short=8", "HEAD"),
            "release_branch": "", "tag": "v0.1.0+2"})

    def test_stdout_and_github_output_agree_and_the_file_is_appended_to(self):
        target = pathlib.Path(self._dir.name) / "gh_output"
        target.write_text("earlier=step\n", encoding="utf-8")
        out = self.prepare(GITHUB_OUTPUT=str(target), RELEASE_BRANCH="dev")
        lines = target.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines[0], "earlier=step")
        got = dict(line.split("=", 1) for line in lines[1:])
        self.assertEqual(got.pop("game_slug"), "launcher-demo")
        self.assertEqual(got, out)
        self.assertEqual((got["release_branch"], got["tag"]), ("dev", "branch-dev"))


class BranchBuild(PrepareHelpers):
    """RELEASE_BRANCH makes a build that must sit next to the real app, not replace it."""

    def test_tag_is_the_rolling_branch_tag(self):
        out = self.prepare(RELEASE_BRANCH="dev")
        self.assertEqual(out["tag"], "branch-dev")
        self.assertEqual(out["release_branch"], "dev")
        self.assertEqual(self.const("RELEASE_BRANCH"), '"dev"')

    def test_names_that_cannot_be_a_tag_and_a_url_segment_are_refused_before_anything_is_written(self):
        before = {n: self.read(n) for n in self.files}
        for bad in ("a/b", "-x", ".x", "a..b", "x.", "x.lock", "a b", "a;b", "é"):
            with self.subTest(branch=bad):
                result = self.run_script("prepare_build.sh", RELEASE_BRANCH=bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::RELEASE_BRANCH", result.stderr)
                for name, text in before.items():
                    self.assertEqual(self.read(name), text, name)

    def test_names_the_app_can_poll_are_accepted(self):
        for good in ("dev", "Feature-1.2", "a_b", "1x", "x.locked", "rc.1"):
            with self.subTest(branch=good):
                self.assertEqual(self.prepare(RELEASE_BRANCH=good)["tag"], "branch-" + good)

    def test_android_package_id_gains_a_segment_and_the_names_a_label(self):
        self.prepare(RELEASE_BRANCH="dev")
        presets = self.read("export_presets.cfg")
        self.assertIn('package/unique_name="com.example.game.dev"', presets)
        self.assertIn('package/name="Game (dev)"', presets)
        self.assertIn('application/product_name="Game (dev)"', presets)
        self.assertIn('application/file_description="Game (dev)"', presets)

    def test_branch_names_are_mapped_to_a_valid_android_segment(self):
        for branch, segment in (("Feature-1.2", "feature_1_2"), ("1x", "b1x"), ("rc.1", "rc_1")):
            with self.subTest(branch=branch):
                self.git("checkout", "-q", "--", "export_presets.cfg", "project.godot")
                self.prepare(RELEASE_BRANCH=branch)
                self.assertIn('package/unique_name="com.example.game.%s"' % segment,
                              self.read("export_presets.cfg"))

    def test_running_it_twice_changes_nothing_the_second_time(self):
        self.prepare(RELEASE_BRANCH="dev")
        first = (self.read("export_presets.cfg"), self.read("project.godot"))
        self.prepare(RELEASE_BRANCH="dev")
        self.assertEqual((self.read("export_presets.cfg"), self.read("project.godot")), first)
        self.assertEqual(self.read("export_presets.cfg").count(".dev"), 1)
        self.assertEqual(self.read("export_presets.cfg").count("(dev)"), 3)

    def test_a_package_id_that_already_ends_in_the_branch_still_gets_a_distinct_id(self):
        # The old guess ("does it already end in .<segment>?") kept the release app's
        # exact id here, so the branch APK would have replaced the player's app.
        self.commit("dev game", {"export_presets.cfg": PRESETS.replace("com.example.game", "com.example.dev")})
        self.prepare(RELEASE_BRANCH="dev")
        self.assertIn('package/unique_name="com.example.dev.dev"', self.read("export_presets.cfg"))

    def test_an_android_preset_without_a_package_id_is_refused_without_a_label_written(self):
        bad = PRESETS.replace('package/unique_name="com.example.game"\n', "")
        self.commit("no package id", {"export_presets.cfg": bad})
        result = self.run_script("prepare_build.sh", RELEASE_BRANCH="dev")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no package/unique_name", result.stderr)
        self.assertNotIn("(dev)", self.read("export_presets.cfg"))

    def test_user_dir_is_separate_and_lands_in_the_application_section(self):
        out = self.prepare(RELEASE_BRANCH="Feature-1.2")
        project = self.read("project.godot")
        start, end = project.index("[application]"), project.index("[display]")
        section = project[start:end]
        self.assertIn("config/use_custom_user_dir=true", section)
        self.assertIn('config/custom_user_dir_name="launcher-demo-feature-1-2"', section)
        self.assertIn('config/name="Launcher Demo"', section)
        self.assertEqual(project[end:], PROJECT[PROJECT.index("[display]"):])
        self.assertEqual(out["tag"], "branch-Feature-1.2")

    def test_existing_user_dir_keys_are_replaced_not_duplicated(self):
        text = PROJECT.replace('config/name="Launcher Demo"\n',
                               'config/name="Launcher Demo"\nconfig/use_custom_user_dir=false\nconfig/custom_user_dir_name="old"\n')
        self.commit("old keys", {"project.godot": text})
        self.prepare(RELEASE_BRANCH="dev")
        project = self.read("project.godot")
        self.assertEqual(project.count("config/use_custom_user_dir"), 1)
        self.assertEqual(project.count("config/custom_user_dir_name"), 1)
        self.assertIn('config/custom_user_dir_name="launcher-demo-dev"', project)
        self.assertIn("config/use_custom_user_dir=true", project)

    def test_a_header_lookalike_inside_a_string_is_not_mistaken_for_the_section(self):
        # Taking the first line that looked like [application] wrote the keys into a
        # multi-line string, destroyed the section, exited 0, and shared user://.
        tricky = PROJECT.replace('run/main_scene="res://main.tscn"\n',
                                 'run/main_scene="res://main.tscn"\nconfig/description="""\n[application]\n"""\n')
        self.commit("tricky", {"project.godot": tricky})
        result = self.run_script("prepare_build.sh", RELEASE_BRANCH="dev")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("2 [application] section headers", result.stderr)
        self.assertEqual(self.read("project.godot"), tricky)

    def test_a_project_with_no_application_section_is_refused(self):
        self.commit("no section", {"project.godot": "config_version=5\n\n[display]\n\nwindow/size/viewport_width=1280\n"})
        result = self.run_script("prepare_build.sh", RELEASE_BRANCH="dev")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("0 [application] section headers", result.stderr)

    def test_a_branch_build_with_no_export_presets_still_gets_its_own_user_dir(self):
        self.git("rm", "-q", "-f", "export_presets.cfg")
        self.git("commit", "-q", "-m", "drop presets")
        result = self.run_script("prepare_build.sh", RELEASE_BRANCH="dev")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "export_presets.cfg").exists())
        self.assertIn('config/custom_user_dir_name="launcher-demo-dev"', self.read("project.godot"))

    def test_a_desktop_only_project_gets_the_labels_and_needs_no_package_id(self):
        desktop = PRESETS[PRESETS.index("[preset.1]"):].replace("preset.1", "preset.0")
        self.commit("desktop only", {"export_presets.cfg": desktop})
        result = self.run_script("prepare_build.sh", RELEASE_BRANCH="dev")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        presets = self.read("export_presets.cfg")
        self.assertIn('application/product_name="Game (dev)"', presets)
        self.assertNotIn("package/unique_name", presets)

    def test_more_names_that_cannot_be_a_tag_and_a_url_segment(self):
        for bad in ("_x", "a~b", "a:b", "a?b", "a*b", "a[b", "a\\b"):
            with self.subTest(branch=bad):
                result = self.run_script("prepare_build.sh", RELEASE_BRANCH=bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::RELEASE_BRANCH", result.stderr)

    def test_awkward_but_valid_names_map_cleanly(self):
        for branch, segment, slug in (("a--b", "a_b", "a-b"), ("dev-", "dev", "dev"), ("block", "block", "block")):
            with self.subTest(branch=branch):
                self.git("checkout", "-q", "--", "export_presets.cfg", "project.godot")
                self.assertEqual(self.prepare(RELEASE_BRANCH=branch)["tag"], "branch-" + branch)
                self.assertIn('package/unique_name="com.example.game.%s"' % segment, self.read("export_presets.cfg"))
                self.assertIn('config/custom_user_dir_name="launcher-demo-%s"' % slug, self.read("project.godot"))

    def test_a_normal_build_leaves_identity_and_user_dir_alone(self):
        self.prepare()
        presets = self.read("export_presets.cfg")
        self.assertIn('package/unique_name="com.example.game"', presets)
        self.assertNotIn("(", presets)
        self.assertEqual(self.read("project.godot"), PROJECT)


if __name__ == "__main__":
    unittest.main()
