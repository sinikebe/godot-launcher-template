"""Tests for ci/new_game.sh, the one-time setup that turns the template into a game.

Each test builds a throwaway repository shaped like a fresh copy of the template, with
its own stand-ins for the files the script edits, copies the script into its ci/, and
runs it with bash, so nothing here touches this checkout and nothing depends on the
files a game has since changed. Standard library only:

    python3 -B -m unittest discover -s ci/tests -v

Needs bash, git and python3, as the script does.
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

# The demo's files, as a repository made from the template has them before setup.
FILES = {
    "version.json": json.dumps({"game_name": "Launcher Demo", "version_name": "0.4.0", "binary_version": 3}) + "\n",
    "export_presets.cfg": 'package/unique_name="com.example.launcherdemo"\npackage/name="Launcher Demo"\n',
    "template/export_presets.cfg": (
        'package/unique_name="com.example.yourgame"\npackage/name="Your Game"\n'
        'application/product_name="Your Game"\napplication/file_description="Your Game"\n'),
    "launcher_config.tres": 'game_title = "LAUNCHER DEMO"\nupdate_repo = "me/template"\n',
    "project.godot": 'config/name="Launcher Demo"\n',
    "LICENSE": "Copyright (c) the template's author\n",
}

ARGS = ("Deep Cavern", "com.yourname.deepcavern", "you/deep-cavern")


class NewGame(unittest.TestCase):
    def setUp(self):
        if shutil.which("git") is None or shutil.which("bash") is None or shutil.which("python3") is None:
            self.skipTest("needs git, bash and python3")
        self.make_repo()

    # -- plumbing ---------------------------------------------------------
    def make_repo(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.root = pathlib.Path(self._dir.name) / "game"
        for name, text in FILES.items():
            self.write(name, text)
        (self.root / "ci").mkdir()
        shutil.copy(CI_DIR / "new_game.sh", self.root / "ci" / "new_game.sh")
        subprocess.run(["git", "init", "-q"], cwd=self.root, env=self.env(), check=True)

    def env(self, path=None):
        return {
            "PATH": path or os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self._dir.name,
            "LANG": "C.UTF-8",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
        }

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def read(self, name):
        return (self.root / name).read_text(encoding="utf-8")

    def setup_game(self, path=None):
        return subprocess.run(["bash", str(self.root / "ci" / "new_game.sh"), *ARGS], cwd=self.root,
                              env=self.env(path), capture_output=True, text=True)

    def without_python(self):
        """A PATH holding everything the script runs except python3."""
        bin_dir = pathlib.Path(self._dir.name) / "bin"
        bin_dir.mkdir()
        for tool in ("bash", "git", "sed", "grep", "tr", "cat", "rm", "mv", "cp"):
            found = shutil.which(tool)
            if found is None:
                self.skipTest("needs %s" % tool)
            (bin_dir / tool).symlink_to(found)
        return str(bin_dir)

    def assert_set_up(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Done. Changed:", result.stdout)
        self.assertFalse((self.root / "template").exists())
        self.assertEqual(json.loads(self.read("version.json"))["game_name"], "Deep Cavern")
        presets = self.read("export_presets.cfg")
        self.assertIn('package/unique_name="com.yourname.deepcavern"', presets)
        self.assertIn('application/product_name="Deep Cavern"', presets)
        self.assertIn('game_title = "Deep Cavern"', self.read("launcher_config.tres"))
        self.assertIn('update_repo = "you/deep-cavern"', self.read("launcher_config.tres"))
        self.assertIn('config/name="Deep Cavern"', self.read("project.godot"))

    # -- tests --------------------------------------------------------------
    def test_a_run_sets_the_game_up_and_removes_template(self):
        self.assert_set_up(self.setup_game())

    def test_a_run_that_stops_partway_can_be_run_again(self):
        """#28: a failure after template/ was removed left the example package id for good."""
        # Each breaks one stage of the setup, and the repair undoes it.
        breakages = {
            "version.json will not parse": (
                lambda: self.write("version.json", '{"game_name": "Launcher Demo",}\n'),
                lambda: self.write("version.json", FILES["version.json"])),
            "launcher_config.tres is not UTF-8": (
                lambda: (self.root / "launcher_config.tres").write_bytes(b'game_title = "\xe9"\n'),
                lambda: self.write("launcher_config.tres", FILES["launcher_config.tres"])),
            "project.godot is a directory": (
                lambda: ((self.root / "project.godot").unlink(), (self.root / "project.godot").mkdir()),
                lambda: ((self.root / "project.godot").rmdir(), self.write("project.godot", FILES["project.godot"]))),
        }
        for what, (break_it, repair) in breakages.items():
            with self.subTest(what):
                self.make_repo()
                break_it()
                failed = self.setup_game()
                self.assertNotEqual(failed.returncode, 0, failed.stdout)
                self.assertNotIn("Done.", failed.stdout)
                self.assertTrue((self.root / "template" / "export_presets.cfg").is_file(),
                                "template/ is gone, so a re-run cannot finish the setup")
                repair()
                self.assert_set_up(self.setup_game())

    def test_without_python3_nothing_is_changed(self):
        failed = self.setup_game(path=self.without_python())
        self.assertNotEqual(failed.returncode, 0, failed.stdout)
        for name, text in FILES.items():
            self.assertEqual(self.read(name), text, "%s changed by a run that could not finish" % name)
        self.assert_set_up(self.setup_game())

    def test_a_finished_setup_is_not_run_twice(self):
        self.assert_set_up(self.setup_game())
        self.write("launcher_config.tres", 'game_title = "Renamed by hand"\nupdate_repo = "you/deep-cavern"\n')
        again = self.setup_game()
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("nothing to do", again.stdout)
        self.assertIn('game_title = "Renamed by hand"', self.read("launcher_config.tres"))
        self.assertTrue((self.root / "LICENSE").is_file())


if __name__ == "__main__":
    unittest.main()
