# Troubleshooting

Symptoms first. Each one is something that has actually happened.

---

## Installing and updating

### Android says "App not installed"

The new APK is signed with a different key than the installed copy, and Android
will not replace an app across a signature change.

Usually it means one of:

- You had no signing secrets, so CI used a throwaway debug key — and the build
  cache holding it expired (7 days without a build), so a new one was generated.
- You added a real keystore after already installing a debug-signed build.
- You replaced your keystore with a different one.

**Fix:** uninstall the old copy, install the new one. Then
[set up a real keystore](GETTING-STARTED.md#android-set-up-signing-before-you-share-it)
so it cannot happen again, and back it up.

### The update downloads, but nothing changed

Your change needed a new binary and shipped as a content pack instead.

A `.pck` can carry scenes, scripts, art and audio. It **cannot** carry project
settings, permissions, a new engine version, a native plugin or a new icon —
those live outside `res://` content.

**Fix:** bump `binary_version` in `version.json` and push again. Players get a
new APK/EXE that actually contains the change.

### The app never notices an update

Check, in order:

1. `update_repo` in `launcher_config.tres` is your game's repo, `owner/name`.
   Not the launcher template's.
2. A release actually exists, and is marked **Latest** on the Releases page.
3. The installed build is genuinely older. A build reports its versions bottom
   right; compare with the release.
4. Open `https://github.com/<owner>/<repo>/releases/latest/download/manifest.json`
   in a browser. If that 404s, the app cannot see anything either.

### It offers an update forever, even right after updating

You are running from the Godot editor, or a locally exported build. Those report
version `0`, so every release looks newer. That is deliberate — it makes the
update path easy to exercise. Installed CI builds behave correctly.

### "Allow … to install unknown apps" keeps coming back

Android requires that permission per installing app, and grants it to the
*installer*, not the file. Grant it to the game itself when the game offers the
update. Granting it to your browser only covers APKs your browser downloads.

### Download fails with a checksum mismatch

The app refuses anything whose SHA-256 does not match the manifest, and discards
it. Press the button again — a truncated download fixes itself on retry.

If it repeats, the release is genuinely inconsistent: re-run the Release
workflow so the manifest and the artifacts are rebuilt together.

---

## Builds

### The Release workflow fails on the Android export

Almost always the Android SDK step. The supplied workflow installs it; if you
edited the workflow, check it still has `android-actions/setup-android` **and**
the step that writes `~/.config/godot/editor_settings-4.7.tres`.

Godot reads the SDK path only from its editor settings — there is no environment
variable fallback — and refuses to export for Android without it.

### The build works but the APK is unsigned

No keystore was available and `keytool` failed. Check the job summary: it says
plainly when it fell back to a debug key.

### Release notes say "No previous release found"

Expected on your first release. The notes come from commits since the last
release tag, and there is no tag yet, so it describes the whole history.

### My change is missing from the patch notes

Subjects starting with `chore`, `ci:`, `bump `, `wip` or `revert` are filtered
out, and merge commits are dropped. Write commit subjects on `main` as if a
player will read them — one will.

---

## The launcher sync

### The sync ran green but there is no pull request

Two possibilities:

1. **Nothing changed.** The job is a no-op when your launcher already matches
   the template. The log says `Already on <sha>; nothing to do.`
2. **Your repository forbids it.** PR creation needs
   *Settings → Actions → General → Allow GitHub Actions to create and approve
   pull requests*. The branch is still pushed; the run summary links a compare
   URL so you can open the PR yourself.

### The sync PR has no CI checks on it

Expected. A pull request opened with the built-in `GITHUB_TOKEN` cannot trigger
other workflows — GitHub blocks that to prevent loops. The sync job imports and
boots your project itself before opening the PR, which covers the realistic
breakage. Use a personal access token instead if you want your full CI on it.

### The sync says my workflows have drifted

Workflow files are the one thing that cannot be synced: a token scoped to
`contents` is not allowed to write `.github/workflows/`. The sync names which
ones, in the run summary of every sync run and in the PR body when one is
opened, under two headings: *changed upstream* (you have the file, it differs)
and *new upstream, not present here* (the template added or split a workflow
and you do not have it at all).

**Fix:** copy them across by hand.

```bash
git clone --depth 1 https://github.com/sinikebe/godot-launcher-template /tmp/lt
cp /tmp/lt/.github/workflows/*.yml .github/workflows/
```

### My change to the launcher disappeared

`addons/launcher/` and `ci/` are replaced wholesale on every sync, so edits
there are reverted without warning.

**Fix:** make the change in the template repository, or — if it is specific to
your game — see whether `launcher_config.tres` already exposes it. If the
launcher genuinely cannot express what you need, that is worth raising upstream
rather than patching locally.

---

## Still stuck

Include the bottom-right stamp from your launcher in any report:

```
v0.2.0 · bin 2 · content 13 · 6721df5d
launcher 2.1.0 · b0f419d7
```

It says which game build and which launcher revision you are on, which is
usually the first thing anyone needs to know.
