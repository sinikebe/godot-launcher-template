---
name: review-oldest
description: Take the oldest open issue, prove the problem is real before touching code, fix it, prove the fix works, and close it. Both proofs are adversarial reviews run by a separate agent that is trying to show you are wrong. Use when asked to review or work the oldest issue, to clear the issue backlog, or when the user says "review oldest".
---

# Review oldest

Work one issue, end to end, with two adversarial gates: one before you write
code and one before you close anything. The gates exist because the two
cheapest ways to waste a day are fixing a problem that was never real, and
closing an issue on a fix that does not work.

## The loop

```
oldest open issue
      │
      ├─ gate 1: is the problem real?  ──── no ──→ close, explain why
      │            (adversarial)
      ↓ yes
   fix it, commit, push
      │
      ├─ gate 2: is it actually fixed? ──── no ──→ iterate, or report and stop
      │            (adversarial)
      ↓ yes
   close, linking the commit
```

## 1. Take the oldest open issue

```
mcp__github__list_issues  state: OPEN, orderBy: CREATED_AT, direction: ASC, perPage: 5
```

Take the first result. Read it in full, including comments — someone may have
already disputed it or started work.

**Skip it and take the next** if it is assigned to somebody, has human activity
in the last few days, or is explicitly a discussion rather than a defect. Say
which issue you skipped and why.

State the issue number and title before going further, so the user can redirect
you if it is not the one they meant.

## 2. Gate 1 — is the problem real?

Dispatch a **separate agent** via the Agent tool. This is the whole point: the
agent that will write the fix must not be the agent that decides the fix is
needed. Fresh context, no investment in the answer.

Prefer a project agent from `.claude/agents/` whose scope matches the files in
question; otherwise `general-purpose`.

Brief it to attack the claim, not to confirm it:

> Issue #N says: `<paste the claim, not your summary of it>`
>
> Your job is to show this is wrong. Re-derive the behaviour from the code as
> it stands on `<branch>` — do not trust the issue's reading of it, and do not
> trust its line numbers. Specifically try to establish any of:
>
> - the described failure cannot actually occur (a guard upstream, a caller
>   that never passes that input, a branch that is unreachable)
> - it was already fixed since the issue was filed
> - the issue misread the code, the API, or the tooling
>
> Where the claim can be settled by running something, run it and paste the
> output. Reasoning about what a command would print is not evidence.
>
> Return one verdict — REAL, NOT REAL, ALREADY FIXED, or UNDETERMINED — with
> the evidence that decided it.

Four verdicts, not two. A forced binary turns thin evidence into a confident
wrong answer, and `UNDETERMINED` is the honest outcome when a claim depends on
runtime behaviour this environment cannot exercise (a device, a real CI run, a
slow network).

## 3. If the problem is not real

Close it. Comment first, explaining what the reviewer found — the person who
filed it deserves to know *why*, in enough detail to disagree.

```
mcp__github__add_issue_comment  issue_number: N, body: <the explanation>
mcp__github__issue_write        method: update, issue_number: N, state: closed,
                                state_reason: not_planned   (or: completed, if already fixed)
```

The comment says which of the three it was — cannot occur, already fixed, or
misread — and shows the evidence. Link the commit if it was fixed since filing.

On `UNDETERMINED`: **leave the issue open.** Comment with what the reviewer
established, what it could not, and exactly what would settle it (a device, a
CI run, a specific measurement). Then stop and tell the user. Do not guess, and
do not fix speculatively — a fix for an unconfirmed problem is a change with no
way to tell whether it helped.

## 4. If the problem is real: fix it

Smallest change that addresses the **root cause**, not the symptom. Stay inside
the issue's scope: if the fix keeps growing, or you find a second bug on the
way, stop, fix only what the issue describes, and report the rest.

Before committing, run whatever this repo actually checks:

```bash
bash ci/collect_changes.sh && bash ci/prepare_build.sh   # in a scratch copy
python3 -m py_compile ci/make_manifest.py
bash -n ci/*.sh
shellcheck --severity=warning ci/*.sh                    # if installed
~/godot/godot --headless --path . --import && \
  ~/godot/godot --headless --path . --quit-after 120     # if Godot is installed
```

Say which of these you actually ran. If a tool is missing from the environment,
say that rather than implying the check passed.

Commit on the session's designated branch and push. **The fix must be pushed
before the issue is closed** — an issue closed against a change that exists
only in a local working tree is a lie in the tracker.

## 5. Gate 2 — is it actually fixed?

Dispatch a **separate agent again**, and not the one that wrote the fix. An
agent reviewing its own patch grades its own homework.

> Issue #N described: `<the original claim>`
> Commit `<sha>` claims to fix it. Diff: `<the diff>`
>
> Your job is to show the issue is still exploitable, or that the fix broke
> something. Try to:
>
> - trigger the original failure against the patched code
> - find an input or path the fix misses — it may have closed one route to the
>   bug and left another
> - find a regression the change introduces
> - confirm it treats the root cause rather than masking the symptom
>
> Run the repo's checks. Paste output, not predictions.
>
> Return FIXED, NOT FIXED, or FIXED WITH NEW PROBLEMS, plus evidence.

**FIXED** → step 6.
**NOT FIXED** → take the finding seriously, revise, and re-run this gate. Two
rounds is normal. If a third round is needed, stop and tell the user what keeps
failing — repeated failures usually mean the diagnosis is wrong, not the patch.
**FIXED WITH NEW PROBLEMS** → fix those too if they are in scope; if not, file
them and say so in the closing comment.

## 6. Close

```
mcp__github__add_issue_comment  issue_number: N, body: <what changed, and the proof>
mcp__github__issue_write        method: update, issue_number: N, state: closed,
                                state_reason: completed
```

Comment first: what the root cause turned out to be, what changed, the commit
link, and how it was verified. If the adversarial review found something you
chose not to address, say so here rather than leaving it for someone to
discover.

Every comment ends with the attribution footer:

```

---
_Generated by [Claude Code](https://claude.ai/code)_
```

Then report to the user: the issue, the verdicts from both gates, what changed,
and what is now the oldest open issue.

## Rules

- **Never close an issue a gate did not clear.** No verdict, no close. This is
  the one rule the skill exists to enforce.
- **Never let the fixer review the fix.** Separate agent, every time.
- **Never treat reasoning as evidence** where a command could settle it. This
  repo's findings are mostly testable in a scratch copy — use one.
- **Never skip, disable, or weaken a check** to make a fix pass.
- **One issue per run.** Finish it, report, stop. Do not roll on to the next.
- **Do not widen the issue.** A fix that touches files the issue never mentioned
  needs a sentence explaining why, or it should be split out.
