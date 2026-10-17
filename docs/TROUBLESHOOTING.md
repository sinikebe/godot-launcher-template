# Troubleshooting

Symptoms first. Each one is something that has actually happened.

---

## Installing and updating

### Android says "App not installed"

The new APK is signed with a different key than the installed copy, and Android
will not replace an app across a signature change.

Usually it means one of:

- You had no signing secrets, so CI used a throwaway debug key — and the build
  cache holding it expired (7 days without a release run — pull-request builds
  do not touch it), so a new one was generated.
- You added a real keystore after already installing a debug-signed build.
- You replaced your keystore with a different one.

**Fix:** uninstall the old copy, install the new one. Then
[set up a real keystore](GETTING-STARTED.md#android-set-up-signing-before-you-share-it)
so it cannot happen again, and back it up.

It also happens when the APK is *older* than the installed copy, such as an
earlier release installed by hand: Android refuses a lower `versionCode`, which
is the content version. Install the newest one instead.

### The update downloads, but nothing changed

Your change needed a new binary and shipped as a content pack instead.

A `.pck` can carry scenes, scripts, art and audio. It **cannot** carry project
settings, permissions, a new engine version, a native plugin or a new icon —
those live outside `res://` content.

**Fix:** bump `binary_version` in `version.json` and push again. Players get a
new APK/EXE that actually contains the change.

Or what you changed belongs to the installed app even with a pack mounted:
`version_name` (the corner stamp and a tagline's `{version}` keep the app
build's; only `content` moves), the launcher line under it, or a
`LauncherConfig` field newer than that app build. See [Version
stamp](../README.md#version-stamp).

### The app never notices an update

Check, in order:

1. `update_repo` in `launcher_config.tres` is your game's repo, `owner/name`,
   or the releases repository it publishes to with `RELEASE_REPO`. Not the
   launcher template's.
2. A release actually exists, and is marked **Latest** on the Releases page.
3. The installed build is genuinely older. A build reports its versions bottom
   right; compare with the release.
4. Open `https://github.com/<owner>/<repo>/releases/latest/download/manifest.json`
   in a browser. If that 404s, the app cannot see anything either; the bar then
   says `No release has been published yet.` A private repository 404s too.

A branch build polls `…/releases/download/branch-<name>/manifest.json` instead,
and its release is a prerelease, never **Latest**. With `check_on_launch` off,
nothing checks until the player presses **Check for updates**.

### It offers an update forever, even right after updating

You are running from the Godot editor, or a locally exported build. Those report
version `0`, so every release looks newer. That is deliberate — it makes the
update path easy to exercise. Installed CI builds behave correctly. On Linux or
macOS the bar says instead `Version <x> needs a new build for linux. Open the
releases page to download it.` (`macos` on a Mac), for the same reason: the
editor's `binary_version` is 0.

### A player cannot reach "Update now" or "Download"

Their launcher is older than 2.4.1, and the update's notes are too long for its
prompt, which pushes the buttons off the bottom of the screen. Updating the
launcher only helps from the update after the one that delivers it. See
[Players on a launcher before 2.4.1](UPDATES.md#players-on-a-launcher-before-241).

### "Allow … to install unknown apps" keeps coming back

Android requires that permission per installing app, and grants it to the
*installer*, not the file. Grant it to the game itself when the game offers the
update. Granting it to your browser only covers APKs your browser downloads.

### Download fails with a checksum mismatch

The app refuses anything whose SHA-256 does not match the manifest, and discards
it. Press **Check for updates**, then download it again — a truncated download
fixes itself on retry.

If it repeats, the release is genuinely inconsistent: re-run the Release
workflow so the manifest and the artifacts are rebuilt together.

### On Windows the game closes for an update and does not come back

The helper could not write over the `.exe`: it sits in a folder the player
cannot write to, such as Program Files, or the game took more than a minute to
close. **Fix:** keep the `.exe` somewhere the player owns, open it, and update
again.

### The bar says "The connection timed out." or "Secure connection failed."

The manifest has 30 seconds to arrive and a download 30 minutes, with no resume.
A slow connection can run out of either; press **Check for updates** to try
again. "Secure connection failed." is often a device clock that is far off,
which makes every certificate look invalid.

### The bar says "update_repo still points at the launcher template"

The game's `launcher_config.tres` still has the template's `update_repo`. Set it
to your game's own repository, or to the releases repository it publishes to.

### The bar says "The update check did not finish."

The check stopped partway, so the launcher gave up on it after 45 seconds and
turned the button back on. If trying again ends the same way every time, the
installed app is older than the content pack it is running, and the pack's
launcher code calls something that app build does not have. A debug build's log
names the call in a `SCRIPT ERROR`. The updater cannot fetch its own fix from
there: reinstall the app from the releases page, whose newest build carries
matching code.

To keep it from reaching players, keep the CI step *Check launcher code still
runs on older binaries* passing; `ci/check_binary_skew.py` lists what it cannot
follow. A connection that stalls past the request's own 30-second limit can end
the same way once, and then trying again works.

---

## Builds

### An export fails with "Invalid export preset name"

The workflows export by preset name. They need one preset called exactly
`Android` and one called exactly `Windows Desktop`. The error lists the
presets your `export_presets.cfg` does have, so rename those, or add the
missing one. A renamed preset of your own also needs the settings listed under
*Export presets* in the README's
[existing-game section](../README.md#add-it-to-an-existing-game). Without them
the build still succeeds, but the APK cannot update itself and the `.exe` is
published without its game data.

If it says instead that the project "doesn't have an `export_presets.cfg` file
at its root", the file never reached the repository. Commit it, and check that
`.gitignore` does not exclude it.

### The Release workflow fails at "Check the release repository"

`RELEASE_REPO` names a separate releases repository, and something about it
would make the publish fail at the end. The error says which:

- **No `RELEASE_TOKEN` secret.** The workflow's own token can write only to the
  repository it runs in.
- **A classic personal access token.** It reaches every repository you can.
  Use a fine-grained token limited to the releases repository.
- **Not an `owner/name`.** `RELEASE_REPO` holds something else, such as a URL
  or a stray space.
- **It does not exist, or is not visible.** Usually a typo in `RELEASE_REPO`.
- **It is private.** Players' apps download with no token. Make it public; it
  holds only releases.
- **It has no commits.** GitHub cannot create a release tag in an empty
  repository. Add a README.

See [Publishing from a private repository](UPDATES.md#publishing-from-a-private-repository).

### The Release workflow fails on the Android export

Almost always the Android SDK step. The supplied workflow installs it; if you
edited the workflow, check it still has `android-actions/setup-android` **and**
the step that writes `~/.config/godot/editor_settings-4.7.tres`.

Godot reads the SDK path only from its editor settings — there is no environment
variable fallback — and refuses to export for Android without it.

If the log instead says `ETC2/ASTC texture compression is required for Android
export`, the project is missing this from `project.godot`:

```ini
[rendering]
textures/vram_compression/import_etc2_astc=true
```

A game made from the template has it. A game that added the launcher by hand
gets it from the README's existing-game steps.

If it fails while signing (the log mentions `apksigner`), the keystore did not
open with your secrets: `ANDROID_KEYSTORE_PASSWORD` is not its password, or
`ANDROID_KEY_ALIAS` is not its alias, or is unset, in which case CI asks for
`androiddebugkey`. Or `ANDROID_KEYSTORE_BASE64` is not set while those two are,
so CI opened its own debug keystore with your password and alias.
`keytool -list -keystore release.keystore` shows the alias.

### The Release workflow fails at "Resolve signing key"

The log says `ANDROID_KEYSTORE_BASE64 did not decode to a usable keystore.` The
secret is not valid base64: it was cut short, or holds something else, such as
the file's path or a stray character. (An empty secret does not fail here; CI
signs with its debug key. One encoded twice decodes here and fails later, at the
Android export.) Set it again from the file:

```bash
base64 < release.keystore | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64
```

### A workflow fails at "Install Godot" with "The cached …"

The cached editor or export templates no longer match what was installed. The
check stops on purpose, and since a cache is never saved over a key it matched,
it fails the same way on every run until the cache is cleared.

**Fix:** delete the `godot-4.7-stable-linux-verified-v1` entry under *Actions →
Caches* (or `gh cache delete godot-4.7-stable-linux-verified-v1`), then run it
again. On a self-hosted runner, delete `~/godot` and
`~/.local/share/godot/export_templates/4.7.stable` as well.

### A branch push fails at "Stamp build version"

The log says `RELEASE_BRANCH is not a usable branch name for a rolling release.`
A branch that publishes a prerelease becomes a tag suffix and a URL segment, so
its name takes only letters, digits, `.`, `_` and `-`, starting with a letter or
digit, with no `..`, and not ending in `.` or `.lock`. A name like `feature/x`
cannot. Rename the branch, or take it out of the list in `release.yml`.

### A build warns that it "checks … for updates, but is published to …"

The build's `update_repo` names one repository and the release goes to another,
so whoever installs it never sees the releases after it. Usually the
`RELEASE_REPO` variable is not set, or names another repository than
`update_repo`; or a `release.yml` from before `RELEASE_REPO` existed ignores it,
so copy the current workflows. It is expected once, while moving a shipped game to a releases
repository; see [Publishing from a private
repository](UPDATES.md#publishing-from-a-private-repository).

### The release says the APK is signed with a CI debug key

No `ANDROID_KEYSTORE_BASE64` secret was set, so CI signed with its cached debug
key; the job summary and the release notes both say so. It installs and updates
until that cache is evicted. [Set up a real
keystore](GETTING-STARTED.md#android-set-up-signing-before-you-share-it) before
anyone else installs it.

### The patch-notes step says "No previous release found"

Expected on your first release: the *Collect patch notes* step found neither a
latest release whose manifest names a commit in this history nor a
`v<name>+<n>` tag, so the notes describe the whole history, capped at 20 lines.
On a later release the line above it says why: `No previous manifest to carry
forward.` (the latest release's `manifest.json` could not be downloaded) or
`…which is not in this history` (the history was rewritten, as by a
force-push). Without `RELEASE_REPO` the `v<name>+<n>` tags here catch either
case; with it, tags are created in the releases repository, so nothing does.

### My change is missing from the patch notes

Merge commits are dropped, and so are subjects starting, in any case, with
`chore`, `ci:`, `bump `, `wip`, `merge ` or `revert ` — so *Wipe old saves* and
*Merge the two inventory screens* go too. A release also lists at most 20 lines:
past that, the oldest are folded into "…and N more changes." Write commit
subjects on `main` as if a player will read them — one will.

---

## The launcher sync

### The sync ran green but there is no pull request

Two possibilities:

1. **Nothing changed.** The job is a no-op when your launcher already matches
   the template. The log says `Already on <sha>; nothing to do.`
2. **Your repository forbids it.** PR creation needs
   *Settings → Actions → General → Allow GitHub Actions to create and approve
   pull requests*. The run stays green and warns `launcher-sync is pushed, but
   this repository does not allow Actions to open pull requests. Open it by
   hand.`; the run summary links a compare URL so you can open the PR yourself.
   A run that ends red with `launcher-sync is pushed, but opening the pull
   request failed. See the run summary.` failed for another reason, which the
   summary quotes.

### The sync PR has no CI checks on it

Expected. A pull request opened with the built-in `GITHUB_TOKEN` cannot trigger
other workflows — GitHub blocks that to prevent loops. The sync imports and
boots your project itself before opening the PR, which covers the realistic
breakage. To run your full CI on it as well, close the pull request and reopen
it, and again after each sync run that updates it. A personal access token also
works, but only by editing `sync-launcher.yml`, which the sync then reports as
changed upstream on every run.

### The sync says my workflows have drifted

Workflow files are the one thing that cannot be synced: a token scoped to
`contents` is not allowed to write `.github/workflows/`. The sync names which
ones, in the run summary of every sync run and in the PR body when one is
opened, under two headings: *changed upstream* (you have the file, it differs)
and *new upstream, not present here* (the template added or split a workflow
and you do not have it at all).

**Fix:** copy them across by hand, then put back any edit of your own, such as
a branch you added to `release.yml`. The runner each job uses and the repository
releases go to are repository variables, not edits, so they never count as
drift; see [Running the workflows on your own
machine](UPDATES.md#running-the-workflows-on-your-own-machine).

```bash
rm -rf /tmp/lt && git clone --depth 1 https://github.com/sinikebe/godot-launcher-template /tmp/lt
cp /tmp/lt/.github/workflows/*.yml .github/workflows/
```

If the run also warns that upstream workflow filenames "are not plain names",
copy nothing: the template repository may have been tampered with.

### My change to the launcher disappeared

`addons/launcher/` and `ci/` are replaced wholesale on every sync, so edits
there are reverted without warning.

**Fix:** make the change in the template repository, or — if it is specific to
your game — see whether `launcher_config.tres` already exposes it, or whether
`_launcher_opening()` in `res://launcher_hooks.gd` can do it. If the
launcher genuinely cannot express what you need, that is worth raising upstream
rather than patching locally.

---

## Still stuck

Include the bottom-right stamp from your launcher in any report:

```
v0.2.0  ·  bin 2  ·  content 13  ·  6721df5d
launcher 2.7.1  ·  b0f419d7
```

It says which app build and content version you are on, and which launcher
that app build shipped with. A content update can bring newer launcher code
without changing the second line, so the `content` number on the first line
matters too.
