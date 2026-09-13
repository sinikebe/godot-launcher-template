# Working conventions

## Nothing lives outside `main`

`main` is the only branch that matters. Work is not done until it is committed,
pushed and **merged**. Never leave work sitting on a feature branch, in a
working tree, or in a session container — those are all lost the moment the
session ends.

A task ends one of two ways: merged to `main`, or an explicit report of what
blocked the merge. There is no third state.

## Issue work goes through a PR named after the issue

When the work comes from an issue, branch off `main` the way GitHub does when
you create a branch from an issue — the issue number, then the slugified title:

```bash
git fetch origin main
git checkout -B "12-background-shaders-aspect-correction-is-inverted" origin/main
```

Open a pull request whose body carries the closing keyword:

```
Closes #12
```

The branch name is for humans reading the branch list. `Closes #12` is what
does the work: it puts the PR in the issue's timeline and closes the issue
automatically on merge — so the issue never has to be closed by hand, and never
gets left open behind a merged fix.

Then merge it, and delete the branch.

## Pull requests

Opening a PR is what gets a change checked: `ci.yml` runs on `pull_request`
only, so a direct push to `main` runs the release workflow and nothing else —
no boot check, no shellcheck.

After opening one, subscribe to it and drive it to green. A red PR is work now,
not something to hand back.

## Attribution

Commits end with:

```
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
```

Comments and PR bodies posted to GitHub end with the Claude Code footer, so a
reader can tell what authored them.
