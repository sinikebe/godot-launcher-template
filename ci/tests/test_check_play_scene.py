"""Tests for ci/check_play_scene.sh, the CI step that boots the scene Play loads.

ci.yml's other boot runs the launcher, so a game's own scenes were exported but never
executed, and a runtime error in one reached a player (#30). The script reads play_scene
from the launcher config, boots it headless and fails on what it logs, because Godot
exits 0 after a runtime error and prints it.

These run it against a stand-in for Godot that records how it was called and prints
what a test tells it to. They prove what the script ASKS for and how it judges the
output; that the real Godot prints what the stand-in is told to print was checked
against Godot 4.7 when the script was written, and is not something these can say.

    python3 -B -m unittest discover -s ci/tests -v
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import unittest

from test_release_dry_run import IS_TEMPLATE
from test_release_scripts import Sandbox

REPO = pathlib.Path(__file__).resolve().parent.parent.parent

FAKE_GODOT = """#!/usr/bin/env bash
{
  echo "args: $*"
  echo "home: $HOME"
  echo "xdg: $XDG_DATA_HOME $XDG_CONFIG_HOME $XDG_CACHE_HOME"
  echo "cwd: $PWD"
} >> "$FAKE_GODOT_LOG"
sleep "${FAKE_GODOT_SLEEP:-0}"
# Real Godot prints its ERROR: and SCRIPT ERROR: lines on stderr and the rest on stdout.
cat "$FAKE_GODOT_OUTPUT" 2>/dev/null
cat "$FAKE_GODOT_STDERR" >&2 2>/dev/null
exit "${FAKE_GODOT_EXIT:-0}"
"""

CONFIG = 'game_title = "Deep Cavern"\nplay_scene = "res://game/play.tscn"\nupdate_repo = "you/deep-cavern"\n'


class CheckPlayScene(Sandbox):
    SCRIPTS = ("check_play_scene.sh",)

    def setUp(self):
        super().setUp()
        self.godot = self.bin / "godot"
        self.godot.write_text(FAKE_GODOT, encoding="utf-8")
        self.godot.chmod(0o755)
        self.godot_log = pathlib.Path(self._dir.name) / "godot.log"
        self.godot_output = pathlib.Path(self._dir.name) / "godot.out"
        self.godot_stderr = pathlib.Path(self._dir.name) / "godot.err"
        (self.root / "launcher_config.tres").write_text(CONFIG, encoding="utf-8")

    def check(self, output="", exit_code=0, godot=True, stderr="", **env):
        self.godot_output.write_text(output, encoding="utf-8")
        self.godot_stderr.write_text(stderr, encoding="utf-8")
        base = {"FAKE_GODOT_LOG": str(self.godot_log), "FAKE_GODOT_OUTPUT": str(self.godot_output),
                "FAKE_GODOT_STDERR": str(self.godot_stderr), "FAKE_GODOT_EXIT": str(exit_code)}
        if godot:
            base["GODOT"] = str(self.godot)
        base.update(env)
        return self.run_script("check_play_scene.sh", **base)

    def calls(self):
        return self.godot_log.read_text(encoding="utf-8").splitlines() if self.godot_log.exists() else []

    def set_config(self, text, name="launcher_config.tres"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    # -- what it boots ------------------------------------------------------
    def test_play_scene_is_booted_headless_from_the_project_for_a_short_run(self):
        result = self.check("Godot Engine v4.7.stable\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = [line for line in self.calls() if line.startswith("args: ")]
        self.assertEqual(args, ["args: --headless --path . res://game/play.tscn --quit-after 120"])
        self.assertIn("cwd: %s" % self.root.resolve(), self.calls())
        self.assertIn("ran without logging an error", result.stdout)

    def test_an_empty_play_scene_boots_nothing_and_passes(self):
        self.set_config('play_scene = ""\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertIn("play_scene is empty", result.stdout)

    def test_a_game_with_no_config_file_boots_nothing_and_passes(self):
        (self.root / "launcher_config.tres").unlink()
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])

    def test_a_config_that_never_mentions_play_scene_boots_nothing(self):
        self.set_config('game_title = "Deep Cavern"\n')
        self.assertEqual(self.check().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_the_config_project_godot_points_at_is_the_one_read(self):
        self.set_config('[launcher]\nconfig_path="res://config/mine.tres"\n', name="project.godot")
        self.set_config('play_scene = "res://game/mine.tscn"\n', name="config/mine.tres")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("args: --headless --path . res://game/mine.tscn --quit-after 120", self.calls())

    def test_a_key_that_merely_ends_in_play_scene_is_not_it(self):
        self.set_config('my_play_scene = "res://game/wrong.tscn"\nplay_scene = "res://game/right.tscn"\n')
        self.assertEqual(self.check().returncode, 0)
        self.assertIn("args: --headless --path . res://game/right.tscn --quit-after 120", self.calls())

    def test_the_line_may_be_written_without_spaces_or_with_windows_line_endings(self):
        for text in ('play_scene="res://game/play.tscn"\n', 'play_scene = "res://game/play.tscn"\r\nupdate_repo = "x/y"\r\n'):
            with self.subTest(text=text):
                self.godot_log.unlink(missing_ok=True)
                self.set_config(text)
                result = self.check()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("args: --headless --path . res://game/play.tscn --quit-after 120", self.calls())

    def test_a_uid_path_is_passed_through(self):
        self.set_config('play_scene = "uid://b8x7m2k4q1w9z"\n')
        self.assertEqual(self.check().returncode, 0)
        self.assertIn("args: --headless --path . uid://b8x7m2k4q1w9z --quit-after 120", self.calls())

    def test_a_value_that_is_not_a_scene_path_is_refused_before_godot_can_read_it_as_an_option(self):
        for value in ("--script res://evil.gd", "--help", "game/play.tscn"):
            with self.subTest(value=value):
                self.set_config('play_scene = "%s"\n' % value)
                result = self.check()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("is not a res:// or uid:// path", result.stderr)
                self.assertEqual(self.calls(), [])

    # -- what it judges -----------------------------------------------------
    def test_a_script_error_fails_even_though_godot_exited_zero(self):
        output = ('SCRIPT ERROR: Invalid assignment of property or key \'text\' on a base object of type \'null instance\'.\n'
                  '          at: _ready (res://game/play.gd:4)\n')
        result = self.check(output)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("res://game/play.gd:4", result.stdout)
        self.assertIn("logged errors when it ran", result.stderr)

    def test_errors_godot_prints_on_stderr_are_read_too(self):
        """Real Godot writes ERROR: and SCRIPT ERROR: to stderr; reading stdout alone sees none."""
        result = self.check("Godot Engine v4.7.stable\n", stderr="SCRIPT ERROR: boom\n   at: _ready (res://game/play.gd:4)\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("res://game/play.gd:4", result.stdout)

    def test_a_plain_error_fails_too(self):
        """A scene naming a missing file in an [ext_resource] logs ERROR: and no SCRIPT ERROR:."""
        result = self.check("ERROR: Resource file not found: res://game/nowhere.png (expected type: Texture2D)\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_a_scene_that_could_not_be_loaded_fails_on_godots_exit_status(self):
        result = self.check("", exit_code=1)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Godot exited with status 1", result.stderr)

    def test_the_scenes_own_exit_status_is_not_lost(self):
        result = self.check("", exit_code=3)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("status 3", result.stderr)

    def test_warnings_and_the_games_own_prints_do_not_fail_it(self):
        output = ("Godot Engine v4.7.stable.official\nWARNING: something deprecated\nloading save data\n"
                  "an ERROR: in the middle of a line, or the word SCRIPT ERROR quoted by the game\n")
        result = self.check(output)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_report_godot_prints_at_exit_is_not_an_error(self):
        """Orphaned nodes and kept RIDs log ERROR: lines on the way out, which no player sees."""
        report = ("WARNING: 3 ObjectDB instances were leaked at exit (run with --verbose for details).\n"
                  "ERROR: 1 resources still in use at exit (run with --verbose for details).\n"
                  "   at: clear (core/io/resource.cpp:822)\n"
                  "ERROR: 2 RID allocations of type 'P11GodotBody2D' were leaked at exit.\n")
        result = self.check("", stderr=report)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Not counted: the ERROR lines above", result.stdout)

    def test_nothing_is_said_about_uncounted_lines_when_there_were_none(self):
        self.assertNotIn("Not counted", self.check("Godot Engine v4.7.stable\n").stdout)

    def test_a_real_error_is_still_found_beside_the_exit_report(self):
        report = ("SCRIPT ERROR: Invalid call. Nonexistent function 'boom' in base 'Nil'.\n"
                  "ERROR: 1 resources still in use at exit (run with --verbose for details).\n")
        self.assertEqual(self.check("", stderr=report).returncode, 1)

    def test_a_shader_error_fails(self):
        result = self.check("", stderr="SHADER ERROR: Unknown identifier in expression: 'COLOUR'.\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_godot_only_runs_what_ends_like_a_scene_so_anything_else_is_refused(self):
        """Godot ignores any other argument and boots the main scene, exit 0: the check would pass unrun."""
        for value in ("res://game/play", "res://game/play.gd", "res://game/play.png", "res://game/play.TSCN",
                      "res://game/play.tscn.bak", "res://game/"):
            with self.subTest(value=value):
                self.set_config('play_scene = "%s"\n' % value)
                result = self.check()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("does not end in .tscn, .scn, .escn or .res", result.stderr)
                self.assertEqual(self.calls(), [])
        for value in ("res://game/play.tscn", "res://game/play.scn", "res://game/play.escn", "res://game/play.res"):
            with self.subTest(value=value):
                self.godot_log.unlink(missing_ok=True)
                self.set_config('play_scene = "%s"\n' % value)
                self.assertEqual(self.check().returncode, 0)
                self.assertIn("args: --headless --path . %s --quit-after 120" % value, self.calls())

    @unittest.skipUnless(shutil.which("timeout"), "needs timeout, which the script uses where it is")
    def test_a_scene_that_never_yields_is_ended_and_fails(self):
        """A loop in _ready() never reaches --quit-after: without a limit it holds the job for hours."""
        result = self.check("", FAKE_GODOT_SLEEP="30", PLAY_SCENE_TIMEOUT="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("was still running after 1 seconds", result.stderr)

    # -- how it runs --------------------------------------------------------
    def test_godot_runs_in_a_scratch_home_that_is_removed_afterwards(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        home = [line for line in self.calls() if line.startswith("home: ")][0][len("home: "):]
        self.assertNotEqual(pathlib.Path(home), self.home)
        self.assertFalse(pathlib.Path(home).exists(), "the scratch home was left behind")
        # user:// lives under the XDG directories, so they must be in the scratch home too.
        xdg = [line for line in self.calls() if line.startswith("xdg: ")][0][len("xdg: "):].split()
        self.assertEqual(len(xdg), 3)
        for directory in xdg:
            self.assertTrue(directory.startswith(home + "/"), "%s is outside the scratch home %s" % (directory, home))

    def test_it_finds_the_project_from_wherever_it_is_run(self):
        elsewhere = pathlib.Path(self._dir.name) / "elsewhere"
        elsewhere.mkdir()
        self.godot_output.write_text("", encoding="utf-8")
        env = self.env(GODOT=str(self.godot), FAKE_GODOT_LOG=str(self.godot_log),
                       FAKE_GODOT_OUTPUT=str(self.godot_output), FAKE_GODOT_STDERR=str(self.godot_stderr))
        result = subprocess.run(["bash", str(self.root / "ci" / "check_play_scene.sh")], cwd=elsewhere,
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("cwd: %s" % self.root.resolve(), self.calls())

    def test_godot_defaults_to_where_install_godot_puts_it_and_is_found_before_home_changes(self):
        default = self.home / "godot" / "godot"
        default.parent.mkdir()
        default.write_text(FAKE_GODOT, encoding="utf-8")
        default.chmod(0o755)
        result = self.check(godot=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len([c for c in self.calls() if c.startswith("args: ")]), 1)

    def test_a_missing_godot_says_so_instead_of_passing(self):
        result = self.check(godot=False)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Godot is not at", result.stderr)

    # -- the workflow -------------------------------------------------------
    @unittest.skipUnless(IS_TEMPLATE, "a game's ci.yml is its own, and copying it across is its choice")
    def test_the_templates_ci_runs_it_after_the_project_is_imported(self):
        text = (REPO / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("run: bash ci/check_play_scene.sh", text)
        self.assertLess(text.index("name: Import project"), text.index("run: bash ci/check_play_scene.sh"),
                        "the scene is booted before the project is imported")


if __name__ == "__main__":
    unittest.main()
