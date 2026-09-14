# How updating works

## The two version numbers

Everything follows from splitting "what changed" into two questions.

| | Bumped | Delivered as | Lives in |
|---|---|---|---|
| `binary_version` | By hand, in [`version.json`](../version.json) | A new APK / EXE | `version.json` |
| `content_version` | Automatically, every release | A `.pck` content pack | Commit count on `main` |

**Bump `binary_version`** when the change cannot possibly ride inside a `.pck`:

- upgrading Godot, or changing the export templates
- adding or removing an Android permission
- adding a native/GDExtension plugin
- changing the app icon, package name, or anything in `export_presets.cfg`
- changing project settings (a pack cannot re-apply `project.godot`)

**Leave it alone** for everything else — scenes, scripts, shaders, art, audio,
balance. Those ship as a content pack, which is a few tens of kilobytes instead
of a ~57 MB APK, and applies with a restart instead of a reinstall.

`content_version` is the commit count on `main` (`git rev-list --count HEAD`).
It is monotonic, moves on every merge, and needs no bookkeeping.

## What happens at launch

1. `BuildInfo` (first autoload) captures the binary's own versions from the
   generated [`build_version.gd`](../build_version.gd). This
   happens via `preload`, which resolves before any pack is mounted — so it
   always describes the APK/EXE itself, never a pack that later shadows it.
2. If `user://update_state.json` points at a staged pack whose version is
   *strictly greater* than the binary's own content version, the pack is mounted
   with `ProjectSettings.load_resource_pack()`. Anything at or below is stale —
   it was superseded by a binary update — and gets deleted.
3. The main scene loads, already seeing the pack's content.
4. The menu fetches the manifest and decides what, if anything, to offer.

Packs are stored per-version (`user://content/content-<n>.pck`) rather than
under one name. A mounted pack stays locked for the life of the process on
Windows, so a new download must never try to overwrite the one in use.

## The manifest

Published as a release asset and fetched from a single fixed URL:

```
https://github.com/<owner>/<game>/releases/latest/download/manifest.json
```

`/releases/latest/download/<name>` always redirects to the newest release, so a
shipped build never has to know a tag, call the GitHub API, or worry about rate
limits. That is also why every asset name is version-free — `<game>.apk`, not
`<game>-0.1.0.apk`.

The artifact URLs *inside* the manifest are different: they are pinned to that
release's own tag, not to `latest`. GitHub's CDN caches the two paths
independently, so for a while after a release goes out,
`latest/download/manifest.json` can still serve the previous manifest while
`latest/download/<game>.apk` already serves the new binary — observed in
practice, not theoretical. Pinning makes each manifest internally consistent: a
client handed a stale manifest installs that slightly older release and catches
up on its next check, instead of pairing one release's checksum with another
release's bytes and refusing the update.

For the same reason the app appends a unique `?ts=` to its manifest request —
GitHub ignores `Cache-Control` on that path, and a cache-buster is what actually
gets a fresh answer.

```jsonc
{
  "schema": 1,
  "version_name": "0.1.0",
  "binary_version": 1,
  "content_version": 12,
  "commit": "a1b2c3d4",
  "release_tag": "v0.1.0+12",
  "released_at": "2026-09-13T12:00:00Z",
  "artifacts": {
    "binary":  { "android": { "file": "…", "url": "…", "size": 0, "sha256": "…" },
                 "windows": { … } },
    "content": { "android": { … }, "windows": { … } }
  },
  "changelog": [
    { "content_version": 12, "binary_version": 1, "version_name": "0.1.0",
      "released_at": "…", "changes": ["Add the spore bloom", "Fix menu focus"] },
    { "content_version": 11, … }
  ]
}
```

The client compares `binary_version` first. A new binary wins over a pending
content pack, because the binary carries its own content anyway.

Every download is hashed and compared against `sha256` before it is installed.
A mismatch is deleted, not installed. An artifact with no checksum is refused
outright — an unauthenticated binary is worse than no update.

## Patch notes

Every release carries its own notes, and the menu shows them *before* the
download starts — so nobody is asked to spend 50 MB on an unexplained update.

They are generated, not hand-written. [`ci/collect_changes.sh`](../ci/collect_changes.sh)
takes the commit subjects between the previous release tag and `HEAD`, drops the
housekeeping ones (`chore`, `ci:`, `bump `, `wip`, `revert`, merges), and hands
the rest to the manifest builder. The same list goes into the GitHub release body.

**Write commit subjects on `main` as if a player will read them, because one
will.** Squash-merging a PR with a tidy subject is the easiest way to get this
right.

The manifest carries a rolling `changelog` of the last 20 releases rather than
just the newest entry, and the app shows every entry above its own
`content_version`. Someone who has not launched the game in six releases sees all
six, newest first, instead of one line about the latest. Each release carries the
previous manifest's changelog forward, so the history accumulates without anyone
maintaining a file.

If a release has no notes at all, the dialog is skipped entirely and the update
applies directly — an empty dialog is worse than no dialog.

### Reading them at any time

**What's new** in the update bar opens the full history, whether or not an
update is pending, with the running build marked. It is hidden when neither
source below has anything to show -- a button that only opens "nothing recorded
yet" is worse than no button, and a release of nothing but chore commits ships
an entry with an empty `changes` list. It works with no network, from two
sources:

- the changelog from the last successful check, cached at
  `user://changelog.json`;
- the running build's *own* notes, baked into `build_version.gd` at
  build time, so a fresh install can describe itself before it has ever reached
  the network.

The dialog caps its height and scrolls, so a long history cannot push the
buttons off-screen.

## Per-platform behaviour

### Android — in-place self-update

The APK is downloaded to private storage, verified, then handed to the system
installer via `OS.shell_open()`. Godot's Android implementation routes a file
path through its bundled `FileProvider` (authority `<package>.fileprovider`),
resolves the MIME type to `application/vnd.android.package-archive`, and attaches
a read-URI grant so the installer can open a file in our private `files` dir.

This needs `REQUEST_INSTALL_PACKAGES`, which is declared in the export preset.
The app pre-checks `canRequestPackageInstalls()` and sends the user to the
relevant settings screen if it is off; if that check cannot run, the install
intent is attempted anyway, since the system installer prompts on its own.

> **Note.** With the prebuilt (non-Gradle) Android export, Godot rewrites *every*
> `<provider>` authority to `<package>.fileprovider`, which collides with
> androidx-startup's provider. `FileProvider` is declared first and wins the
> authority registration; the duplicate is skipped with a warning, disabling
> androidx `ProfileInstaller` — a startup optimisation, not a correctness issue.
> If a future change needs androidx-startup, switch the preset to
> `gradle_build/use_gradle_build=true` and bump `binary_version`.

### Windows — swap on exit

The Windows build is a single self-contained `.exe` (the pack is embedded at
export time), so installing an update is one file copy. A running executable
cannot overwrite itself, so the app writes a small PowerShell helper that waits
for the game's PID to exit, copies the new file over the old one, and relaunches.

### Content updates, everywhere

Downloaded, verified, moved into `user://content/`, recorded in
`user://update_state.json`, then the app offers to restart. On Android the
restart goes through `ProcessPhoenix`, the restart helper already inside Godot's
Android library; on desktop it relaunches `OS.get_executable_path()`. If neither
works the user is simply asked to reopen the app.

## Signing

**Android will not install an update over an app signed with a different key.**
Stable signing is therefore what makes self-update work at all, not a detail.

The release workflow uses, in order of preference:

1. **A release keystore from repository secrets.** The intended setup.
2. **A CI-generated debug key**, kept alive in the Actions cache under a fixed
   key so the signature stays stable between runs. This exists so the pipeline
   produces an installable APK before anyone configures signing. Actions caches
   are evicted after 7 days without a hit; if that happens a new key is generated
   and already-installed copies can no longer be updated in place.

### Setting up a release keystore

Create one (any machine with a JDK):

```bash
keytool -genkeypair -v \
  -keystore release.keystore \
  -alias release \
  -keyalg RSA -keysize 2048 -validity 10950 \
  -dname "CN=YourGame, O=<owner>, C=FR"
```

Then add three repository secrets:

```bash
gh secret set ANDROID_KEYSTORE_BASE64  < <(base64 -w0 release.keystore)
gh secret set ANDROID_KEYSTORE_PASSWORD  # the store password you chose
gh secret set ANDROID_KEY_ALIAS          # release
```

**Back the keystore file up somewhere you control, outside this repository.**
Lose it and you can never ship an in-place update to anyone who installed a
build signed with it — they would have to uninstall and reinstall.

Switching from the debug fallback to a real keystore changes the signature, so
anyone already running a debug-signed build has to reinstall once. Do it before
sharing builds, not after.

### How the secret is kept out of reach

- The workflow only runs on `push` to `main` and manual dispatch. Pull requests
  go through `ci.yml`, which has no secrets and publishes nothing — so a fork PR
  can never reach the key.
- `contents: write` is granted to the release job only; the workflow default is
  `contents: read`.
- The keystore is written under `$RUNNER_TEMP`, outside the workspace, so no
  release or artifact glob can sweep it up. It is deleted in an `always()` step.
- The base64 blob is piped through stdin, never passed as an argument (arguments
  are visible in the process table).
- Passwords are injected straight from the `secrets` context into the export
  step's `env`, where Actions masks them. They never reach a file, a step output,
  or `$GITHUB_ENV` (which is *not* masked).
- Godot redacts the keystore path and password from its own `apksigner` log line.

## Releasing a change

Merge to `main`. The workflow exports, hashes, writes the manifest, and publishes
the release tagged `v<version_name>+<content_version>`.

Bump `binary_version` in `version.json` in the same commit if the change needs a
new binary. If you forget, players on the old binary will download a content pack
that cannot actually deliver the change — bump it and merge again to correct.

## Testing the update path

The fastest loop, without touching a phone:

1. Run the project from the editor. It reports version `0`/`0`, so any published
   release looks newer and the menu offers the update immediately.
2. To test content updates specifically, publish a release, then run a build
   whose `content_version` is lower than the published one.
3. `user://` is `%APPDATA%\Godot\app_userdata\the game` on Windows. Delete
   `update_state.json` and `content/` there to reset a machine to stock content.
