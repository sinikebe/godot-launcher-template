#!/usr/bin/env python3
"""Fails when launcher code that ships in content packs relies on something an
older installed binary does not have.

BuildInfo is the first autoload because it mounts the content pack, so
build_info.gd always runs at the version the installed binary was built with.
So does everything it references while compiling: launcher_config.gd (it names
the LauncherConfig class), launcher_version.gd and build_version.gd (preloaded).
The rest of addons/launcher/ -- update_service.gd, launcher.gd and the rest --
loads after the mount, from the pack. A pack can therefore run against any
binary this repository ever built, and a member that pack-side code reads
directly but an older binary lacks fails at runtime there. #24 predicted it and
#70 is the proof: one such read at the top of check_for_updates() left every
older binary with an updater that could never run again, and so could never
fetch the release that fixed it.

This reads every version of those binary-side scripts in this repository's
history, keeps the members present in all of them and the argument counts all
of them accept, and checks each direct access from pack-side code against that.
In a game the history starts at its first launcher sync, which is exactly the
oldest binary it can have shipped.

Reaching a newer member by name -- "member" in obj, obj.get(), has_method(),
obj.call() -- is how pack-side code is meant to use one, with the older
binary's behaviour as the fallback. This script does not follow those, which is
the point. Nor does it follow a value through an untyped variable: it knows
BuildInfo, BuildInfo.config, the LauncherConfig class, and names declared as
LauncherConfig or assigned from BuildInfo.config.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

sys.dont_write_bytecode = True  # importing make_pot must not leave ci/__pycache__ behind
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from make_pot import line_of, mask  # noqa: E402

SOURCE_DIR = pathlib.Path("addons/launcher")

# Scripts compiled from the binary, by the name pack-side code reaches them with.
PINNED = {
    "BuildInfo": "addons/launcher/build_info.gd",
    "LauncherConfig": "addons/launcher/launcher_config.gd",
    "LauncherVersion": "addons/launcher/launcher_version.gd",
    "BuildVersion": "build_version.gd",
}

# A game's own script for the launcher's screen runs from the pack against the
# same binary-side objects, so it is held to the same rule when it exists.
GAME_HOOKS = pathlib.Path("launcher_hooks.gd")

# Members every binary has because the engine provides them: Object, Node and
# Resource API that pack-side code reaches through BuildInfo or the config.
ENGINE_MEMBERS = {
    "get", "set", "call", "callv", "has_method", "has_signal", "connect",
    "disconnect", "is_connected", "emit_signal", "get_script", "get_meta",
    "set_meta", "has_meta", "get_class", "is_class", "get_method_list",
    "get_property_list", "get_signal_list", "notification", "get_instance_id",
    "tr", "tr_n", "name", "get_name", "get_tree", "get_node", "get_parent",
    "is_inside_tree", "is_node_ready", "resource_path", "resource_name",
    "duplicate", "changed", "emit_changed",
}

TOP_MEMBER = re.compile(
    r"^(?:@\w+(?:\([^\n]*?\))?\s+)*(?:static\s+)?(var|const|signal|enum|func)\s+(\w+)", re.M)
FUNC_PARAMS = re.compile(r"^(?:static\s+)?func\s+(\w+)\s*\(", re.M)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def split_args(masked: str, open_paren: int) -> tuple[list[str], int]:
    """Top-level comma-separated pieces between the paren at open_paren and its match."""
    depth, start, pieces = 0, open_paren + 1, []
    for i in range(open_paren, len(masked)):
        ch = masked[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                last = masked[start:i].strip()
                if last or pieces:
                    pieces.append(last)
                return pieces, i
        elif ch == "," and depth == 1:
            pieces.append(masked[start:i].strip())
            start = i + 1
    return pieces, len(masked)


class Api:
    """One version of a binary-side script: its members and its functions' arities."""

    def __init__(self, source: str):
        masked, _ = mask(source)
        self.members = {m.group(2) for m in TOP_MEMBER.finditer(masked)}
        self.arity: dict[str, tuple[int, int]] = {}
        for match in FUNC_PARAMS.finditer(masked):
            params, _ = split_args(masked, match.end() - 1)
            params = [p for p in params if p]
            optional = sum(1 for p in params if "=" in p)
            self.arity[match.group(1)] = (len(params) - optional, len(params))


def history(path: str) -> list[tuple[str, Api]]:
    """Every version of path reachable from HEAD, plus the working tree's."""
    versions: list[tuple[str, Api]] = []
    for commit in git("log", "--format=%H", "HEAD", "--", path).split():
        try:
            versions.append((commit[:8], Api(git("show", f"{commit}:{path}"))))
        except subprocess.CalledProcessError:
            continue  # the commit that deleted it
    if pathlib.Path(path).exists():
        versions.append(("worktree", Api(pathlib.Path(path).read_text(encoding="utf-8"))))
    return versions


def pack_side_files() -> list[pathlib.Path]:
    pinned = {pathlib.Path(p) for p in PINNED.values()}
    files = sorted(p for p in SOURCE_DIR.rglob("*.gd") if p not in pinned)
    if GAME_HOOKS.exists():
        files.append(GAME_HOOKS)
    return files


def accesses(masked: str, literals: list[str]) -> list[tuple[str, str, int, int | None]]:
    """(pinned name, member, position, argument count or None) for each direct access."""
    aliases = {"BuildInfo": "BuildInfo", "BuildInfo.config": "LauncherConfig",
               "LauncherConfig": "LauncherConfig"}
    for match in re.finditer(r"\b(\w+)\s*:\s*LauncherConfig\b", masked):
        aliases[match.group(1)] = "LauncherConfig"
    # The config itself, not a value read off it: BuildInfo.config.x(...) is no alias.
    for match in re.finditer(r"\b(?:var|const)\s+(\w+)\s*:?=\s*BuildInfo\.config\b(?!\s*[.(\[])", masked):
        aliases[match.group(1)] = "LauncherConfig"
    for match in re.finditer(r"\b(?:var|const)\s+(\w+)\s*:?=\s*(?:pre)?load\(\s*\x00(\d+)\x00\s*\)", masked):
        target = literals[int(match.group(2))].removeprefix("res://")
        for name, path in PINNED.items():
            if target == path:
                aliases[match.group(1)] = name

    found = []
    # Longest alias first, so "BuildInfo.config.x" is read as the config's x.
    for alias in sorted(aliases, key=len, reverse=True):
        pattern = re.compile(r"(?<![\w.])" + re.escape(alias) + r"\.(\w+)(\s*\()?")
        for match in pattern.finditer(masked):
            if alias == "BuildInfo" and match.group(1) == "config" and \
                    masked.startswith(".", match.end(1)):
                continue  # handled as BuildInfo.config.<member>
            argc = None
            if match.group(2):
                argc = len(split_args(masked, match.end() - 1)[0])
            found.append((aliases[alias], match.group(1), match.start(), argc))
    return found


def main() -> int:
    if not SOURCE_DIR.is_dir():
        sys.exit(f"run from the repository root: {SOURCE_DIR} not found")
    if git("rev-parse", "--is-shallow-repository").strip() == "true":
        print("::warning::shallow clone: only the history fetched is checked; "
              "check out with fetch-depth: 0 to cover every binary", file=sys.stderr)

    apis = {name: history(path) for name, path in PINNED.items()}
    problems: list[str] = []
    checked = 0
    for path in pack_side_files():
        masked, literals = mask(path.read_text(encoding="utf-8"))
        for pinned, member, pos, argc in accesses(masked, literals):
            versions = apis[pinned]
            if not versions or member in ENGINE_MEMBERS:
                continue
            checked += 1
            missing = [label for label, api in versions if member not in api.members]
            bad_arity = []
            if argc is not None:
                for label, api in versions:
                    if member in api.arity:
                        low, high = api.arity[member]
                        if not low <= argc <= high:
                            bad_arity.append(f"{label} takes {low}-{high}" if low != high
                                             else f"{label} takes {low}")
            line = line_of(masked, pos)
            if missing:
                problems.append(
                    f"file={path},line={line}::{pinned}.{member} is missing from "
                    f"{len(missing)} of {len(versions)} versions of {PINNED[pinned]} "
                    f"({', '.join(missing[:4])}{', ...' if len(missing) > 4 else ''}). "
                    f"Read it by name with a fallback (\"{member}\" in ..., has_method(), call()).")
            elif bad_arity:
                problems.append(
                    f"file={path},line={line}::{pinned}.{member}() called with {argc} "
                    f"argument(s), which {len(bad_arity)} of {len(versions)} versions of "
                    f"{PINNED[pinned]} reject ({'; '.join(bad_arity[:4])}"
                    f"{'; ...' if len(bad_arity) > 4 else ''}). Check the arity before calling.")

    for problem in problems:
        print(f"::error {problem}", file=sys.stderr)
    counts = ", ".join(f"{len(v)} of {PINNED[n]}" for n, v in apis.items())
    if problems:
        print(f"{len(problems)} access(es) an older binary cannot satisfy. Versions read: {counts}.",
              file=sys.stderr)
        return 1
    print(f"{checked} direct access(es) to binary-side code, all satisfied by every version: {counts}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
