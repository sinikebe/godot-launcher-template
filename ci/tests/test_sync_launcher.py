"""Tests for ci/sync_launcher.sh, the daily job that pulls the launcher into a game.

Each test builds a throwaway template repository and a game repository, points the
template's GitHub URL at the local one with a url.insteadOf rewrite, and runs the
script the way sync-launcher.yml does: from a copy outside ci/, because the sync
overwrites ci/ while it runs. Standard library only:

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
LAUNCHER_VERSION = (CI_DIR.parent / "addons" / "launcher" / "launcher_version.gd").read_text(encoding="utf-8")
class SyncLauncher(unittest.TestCase):
    TEMPLATE = "me/template"

    def setUp(self):
        if shutil.which("git") is None or shutil.which("bash") is None or shutil.which("python3") is None:
            self.skipTest("needs git, bash and python3")
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        base = pathlib.Path(self._dir.name)
        self.gitconfig = base / "gitconfig"
        self.template = base / "template"
        self.bare = base / "template.git"
        self.game = base / "game"
        self.temp = base / "runner_temp"
        self.temp.mkdir()
        self.gitconfig.write_text(
            '[url "file://%s"]\n\tinsteadOf = https://github.com/%s.git\n'
            "[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n" % (self.bare, self.TEMPLATE),
            encoding="utf-8")

        # The template: a launcher, a version file holding the template's own defaults,
        # this checkout's ci/sync_launcher.sh, and one workflow.
        self.make_repo(self.template, {
            "addons/launcher/launcher_version.gd": LAUNCHER_VERSION,
            "addons/launcher/launcher.gd": "extends Control\n",
            "ci/sync_launcher.sh": (CI_DIR / "sync_launcher.sh").read_text(encoding="utf-8"),
            ".github/workflows/ci.yml": "name: CI\n",
        }, "Template commit")
        self.git(self.template.parent, "clone", "-q", "--bare", str(self.template), str(self.bare))

        # The game: its own file, the same sync script and workflow, no launcher yet.
        self.make_repo(self.game, {
            "game.txt": "mine\n",
            "ci/sync_launcher.sh": (CI_DIR / "sync_launcher.sh").read_text(encoding="utf-8"),
            ".github/workflows/ci.yml": "name: CI\n",
        }, "Game commit")

    # -- plumbing ---------------------------------------------------------
    def env(self):
        return {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self._dir.name,
            "LANG": "C.UTF-8",
            "GIT_CONFIG_GLOBAL": str(self.gitconfig),
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
        }

    def git(self, where, *args):
        return subprocess.run(["git", *args], cwd=where, env=self.env(), check=True,
                              capture_output=True, text=True).stdout.strip()

    def make_repo(self, where, files, message):
        where.mkdir(parents=True)
        self.git(where, "init", "-q")
        self.write(where, files)
        self.git(where, "add", "-A")
        self.git(where, "commit", "-q", "-m", message)

    @staticmethod
    def write(where, files):
        for name, text in files.items():
            path = where / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")

    def sync(self, ref="main"):
        """As sync-launcher.yml runs it: from a copy, because the sync replaces ci/."""
        copy = self.temp / "sync_launcher.sh"
        shutil.copy(self.game / "ci" / "sync_launcher.sh", copy)
        env = self.env()
        env.update({"LAUNCHER_TEMPLATE_REPO": self.TEMPLATE, "LAUNCHER_TEMPLATE_REF": ref,
                    "RUNNER_TEMP": str(self.temp), "GITHUB_OUTPUT": str(self.temp / "output")})
        result = subprocess.run(["bash", str(copy)], cwd=self.game, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def commit_game(self, message="Merge the sync"):
        self.git(self.game, "add", "-A")
        self.git(self.game, "commit", "-q", "-m", message)

    def record(self):
        return json.loads((self.game / "addons/launcher/.launcher-sync.json").read_text(encoding="utf-8"))

    def stamp(self):
        text = (self.game / "addons/launcher/launcher_version.gd").read_text(encoding="utf-8")
        return dict(re.findall(r'^const (COMMIT|SYNCED_AT|SOURCE): String = "(.*)"$', text, re.M))

    def unstamp(self):
        """What a game that crossed into stamping was left with (#22)."""
        path = self.game / "addons/launcher/launcher_version.gd"
        text = path.read_text(encoding="utf-8")
        for const, value in (("COMMIT", "local"), ("SYNCED_AT", ""), ("SOURCE", "")):
            text = re.sub(r'^const %s: String = ".*"$' % const, 'const %s: String = "%s"' % (const, value), text, flags=re.M)
        path.write_text(text, encoding="utf-8")

    # -- tests --------------------------------------------------------------
    def test_a_sync_stamps_the_launcher_with_what_its_record_says(self):
        result = self.sync()
        self.assertIn("Synced launcher to", result.stdout)
        record = self.record()
        self.assertEqual(self.stamp(), {"COMMIT": record["commit"][:8], "SYNCED_AT": record["synced_at"],
                                        "SOURCE": self.TEMPLATE})

    def test_an_unstamped_launcher_already_on_the_templates_commit_is_stamped_on_the_next_run(self):
        # The sync that delivered stamping ran the copy from before it, and every run
        # after it, with the template unmoved, exited before stamping: COMMIT stayed
        # "local", which reads as "the template itself".
        self.sync()
        self.unstamp()
        self.commit_game("Merge an unstamped sync")
        result = self.sync()
        self.assertIn("only the launcher's version stamp was missing", result.stdout)
        self.assertIn("Stamped addons/launcher/launcher_version.gd", result.stdout)
        self.assertEqual(self.stamp()["COMMIT"], self.record()["commit"][:8])
        self.assertEqual(self.git(self.game, "status", "--porcelain", "--untracked-files=all").count("\n"), 0)
        self.assertEqual(self.git(self.game, "diff", "--name-only"), "addons/launcher/launcher_version.gd")

    def test_a_run_with_nothing_new_changes_nothing(self):
        # Every value comes from the record, so a second stamp is byte for byte the
        # first, and the daily job opens no pull request.
        self.sync()
        self.commit_game()
        result = self.sync()
        self.assertIn("Already on", result.stdout)
        self.assertNotIn("Stamped", result.stdout)
        self.assertEqual(self.git(self.game, "status", "--porcelain"), "")

    def test_a_new_template_commit_restamps_with_its_own_values(self):
        self.sync()
        self.commit_game()
        first = self.stamp()["COMMIT"]
        self.write(self.template, {"addons/launcher/launcher.gd": "extends Control\n# changed\n"})
        self.git(self.template, "commit", "-qam", "Change the launcher")
        self.git(self.template, "push", "-q", str(self.bare), "HEAD:main")
        self.sync()
        self.assertNotEqual(self.stamp()["COMMIT"], first)
        self.assertEqual(self.stamp()["COMMIT"], self.record()["commit"][:8])

    def test_a_tag_holds_the_sync_until_it_is_changed(self):
        # What the LAUNCHER_TEMPLATE_REF variable does, with a tag shaped like the
        # template's own release tags.
        tagged = self.git(self.template, "rev-parse", "HEAD")
        self.git(self.template, "tag", "v0.1.0+5")
        self.git(self.template, "push", "-q", str(self.bare), "refs/tags/v0.1.0+5")
        self.write(self.template, {"addons/launcher/launcher.gd": "extends Control\n# later\n"})
        self.git(self.template, "commit", "-qam", "Move main on")
        self.git(self.template, "push", "-q", str(self.bare), "HEAD:main")
        self.sync("v0.1.0+5")
        self.assertEqual(self.record()["commit"], tagged)
        self.assertEqual(self.record()["ref"], "v0.1.0+5")
        self.commit_game()
        self.assertIn("Already on", self.sync("v0.1.0+5").stdout)
        self.sync("main")
        self.assertNotEqual(self.record()["commit"], tagged)

    def test_a_record_that_could_break_out_of_the_constant_is_not_used(self):
        # The commit is not tried here: a record naming another commit is simply
        # synced again, which rewrites the record.
        self.sync()
        self.unstamp()
        record = self.record()
        for key, bad in (("source", 'me/x"\nconst Y = 1'), ("synced_at", "now\\")):
            with self.subTest(key=key):
                broken = dict(record, **{key: bad})
                (self.game / "addons/launcher/.launcher-sync.json").write_text(json.dumps(broken), encoding="utf-8")
                self.commit_game("Break the record: %s" % key)
                result = self.sync()
                self.assertIn("::warning::", result.stdout)
                self.assertEqual(self.stamp(), {"COMMIT": "local", "SYNCED_AT": "", "SOURCE": ""})

    def test_a_stamp_for_the_right_commit_is_left_alone(self):
        # Older copies of the script read the clock twice, so SYNCED_AT could be a
        # second off the record's. Rewriting it would open a pull request, and on
        # merge publish a release, for nothing.
        self.sync()
        path = self.game / "addons/launcher/launcher_version.gd"
        path.write_text(re.sub(r'^const SYNCED_AT: String = ".*"$', 'const SYNCED_AT: String = "2000-01-01T00:00:00Z"',
                               path.read_text(encoding="utf-8"), flags=re.M), encoding="utf-8")
        self.commit_game("A stamp a little off the record")
        result = self.sync()
        self.assertIn("nothing to do", result.stdout)
        self.assertEqual(self.git(self.game, "status", "--porcelain"), "")

    def test_a_constant_written_another_way_is_reported(self):
        self.sync()
        self.unstamp()
        path = self.game / "addons/launcher/launcher_version.gd"
        path.write_text(path.read_text(encoding="utf-8").replace('const COMMIT: String = "local"', 'const COMMIT := "local"'),
                        encoding="utf-8")
        self.commit_game("Reformat a constant")
        result = self.sync()
        self.assertIn("::warning::addons/launcher/launcher_version.gd has no line 'const COMMIT: String", result.stdout)


class SyncLauncherOwnerWithUnderscore(SyncLauncher):
    """Managed-user handles hold "_"; the stamp must not refuse them."""
    TEMPLATE = "jdoe_acme/template"


class SyncWorkflow(unittest.TestCase):
    """sync-launcher.yml runs the template's code only in a job that cannot write (#23).

    The check job runs ci/*.sh and the Godot they install straight after the sync,
    before anyone has reviewed them. The job that pushes and opens the pull request
    runs only the game's own copy of the sync script, which copies files.
    """
    # Running something the template supplies: a script under ci/, or the Godot
    # that ci/install_godot.sh put in ~/godot.
    RUNS_TEMPLATE_CODE = re.compile(r"\b(?:bash|sh|source|python3) (?:\./)?ci/|~/godot/")

    def setUp(self):
        # The template's own workflow only: workflows are not synced, so a game's copy
        # may predate this split, and the sync's run summary already says it changed.
        path = CI_DIR.parent / ".github" / "workflows" / "sync-launcher.yml"
        version = CI_DIR.parent / "version.json"
        try:
            is_template = json.loads(version.read_text(encoding="utf-8")).get("game_name") == "Launcher Demo"
        except (OSError, ValueError):
            is_template = False
        if not is_template or not path.is_file():
            self.skipTest("checks the template's own sync-launcher.yml")
        text = path.read_text(encoding="utf-8")
        jobs = text[text.index("\njobs:\n"):]
        self.jobs = dict(re.findall(r"^  ([A-Za-z0-9_-]+):\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", jobs, re.M | re.S))
        self.runners = [name for name, body in self.jobs.items() if self.RUNS_TEMPLATE_CODE.search(body)]
        self.writers = [name for name, body in self.jobs.items() if re.search(r"^      [a-z-]+: write$", body, re.M)]

    def test_there_is_one_job_of_each_kind(self):
        self.assertEqual(len(self.runners), 1, self.jobs.keys())
        self.assertEqual(len(self.writers), 1, self.jobs.keys())
        self.assertNotEqual(self.runners, self.writers)

    def test_the_job_that_runs_the_templates_code_can_only_read(self):
        for name in self.runners:
            body = self.jobs[name]
            self.assertRegex(body, r"(?m)^    permissions:\n      contents: read\n(?!      )", name)
            self.assertNotIn(": write", body, name)
            self.assertNotIn("secrets.", body, name)
            # A token left in .git/config is readable by every later step.
            self.assertIn("persist-credentials: false", body, name)
            # A cache saved after it ran would carry its ~/godot to release.yml.
            self.assertNotRegex(body, r"uses: actions/cache@", name)

    def test_the_job_that_can_write_runs_nothing_from_the_template(self):
        for name in self.writers:
            body = self.jobs[name]
            self.assertNotRegex(body, self.RUNS_TEMPLATE_CODE, name)
            self.assertEqual(re.findall(r"uses: ([\w./-]+)@", body), ["actions/checkout"], name)
            self.assertEqual(re.findall(r"(?m)^ +bash (\S+)", body), ['"${RUNNER_TEMP}/sync_launcher.sh"'], name)

    def test_the_pull_request_is_opened_only_for_the_commit_that_was_checked(self):
        for name in self.writers:
            body = self.jobs[name]
            self.assertRegex(body, r"(?m)^    needs: %s$" % re.escape(self.runners[0]), name)
            self.assertIn("${{ needs.%s.outputs.commit }}" % self.runners[0], body, name)
            opening = body[body.index("- name: Open pull request"):]
            self.assertIn("if: steps.checked.outputs.ok == 'true'", opening.splitlines()[1], name)


if __name__ == "__main__":
    unittest.main()
