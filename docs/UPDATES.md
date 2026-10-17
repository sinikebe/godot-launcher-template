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
balance. Those ship as a content pack: your game's resources without the engine,
so far smaller than the APK (the demo's is about 80 KB, against about 50 MB), and
it applies with a restart instead of a reinstall. A pack carries all of your
resources each time, not only what changed, so it grows with your art and audio.

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
   it was superseded by a binary update — and gets deleted. Before it is
   mounted the pack's size and its `sha256` (recorded in that file when it was
   downloaded) are checked again; a pack that no longer matches is discarded, not
   mounted. Hashing costs about 2 ms per MB on a desktop, so it is cheap next to
   starting the engine. State written before `sha256` was recorded has nothing to
   compare and mounts as before.
3. The main scene loads, already seeing the pack's content. Before the
   launcher builds its screen it runs `_launcher_opening()` from the game's
   `res://launcher_hooks.gd`, when there is one. That file ships in the pack
   too, so catalogs and a language it registers are the pack's, from the first
   frame.
4. The menu fetches the manifest and decides what, if anything, to offer.

Packs are stored per-version (`user://content/content-<n>.pck`) rather than
under one name. A mounted pack stays locked for the life of the process on
Windows, so a new download must never try to overwrite the one in use.

Downloads are staged in `user://staging/` first, and a launch clears out what is
provably dead there rather than emptying it. A second copy of the app may be
downloading into it, an APK may be open in the system installer, and the Windows
helper waits up to a minute for the app to exit before it copies `update-<n>.exe`.
So two rules apply: `update-<n>.apk` and `update-<n>.exe` with *n* at or below this
binary's own `binary_version` are removed (that update is installed), and any other
file of that kind (`*.part`, `apply_update.ps1`, an update for a newer
binary) is removed once more than 24 hours have passed since it was last written. A good APK left by
backing out of the installer therefore stays long enough to be reused. Files the
launcher did not write are left alone.

## The manifest

Published as a release asset and fetched from a single fixed URL:

```
https://github.com/<owner>/<game>/releases/latest/download/manifest.json
```

`<owner>/<game>` is `update_repo` in `launcher_config.tres`: the game's own
repository, or the public releases repository a private game publishes to (see
[Publishing from a private repository](#publishing-from-a-private-repository)).

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
    "content": { "android": { … }, "windows": { … }, "linux": { … }, "macos": { … } }
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
takes the commit subjects since the commit the latest release was built from,
which that release's `manifest.json` records, and drops the housekeeping ones
(`chore`, `ci:`, `bump `, `wip`, `revert`, merges). Without a manifest to read,
it starts at the newest `v<name>+<n>` tag, and with neither, at the first commit.

A release's notes are at most 20 lines. Past that, the 19 newest are kept and the
last line says how many were left out, as in `…and 6 more changes.` That one list
is what the manifest carries, what the build has baked in and what the GitHub
release body shows, so the game and the release page always agree.

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

However long the notes, the dialog's buttons stay on screen: once the notes are
taller than the screen leaves room for, they scroll inside the dialog.

### Players on a launcher before 2.4.1

Before 2.4.1, the update prompt grew with its notes. On a screen 720 pixels
tall, which is what any landscape phone gets with the template's project
settings, notes that wrap to more than about 20 lines start to push the
prompt's buttons past the bottom edge, and by about 25 they are off it
entirely. Nothing else on screen answers a tap while the prompt is open, and a
phone has no Enter key.

The prompt is drawn by the launcher a player already has, so 2.4.1 only helps
from the update after the one that delivers it. While a new app build is on
offer, no content update installs either, so that build's prompt comes from
the old launcher too.

Until your players are on 2.4.1, keep each release's notes short. Nine commit
subjects of 60-odd characters are the most the old prompt holds whole: each
wraps to two lines, and a tenth starts to clip its buttons. A player several
releases behind sees every release they missed in one prompt: up to twelve
lines of release headings, changes and the blank lines between releases, then
"…and N more changes.", and any of those lines can wrap. Releasing often and
squash-merging both help.

A player who is already stuck can close the app (Back does it on Android) and
open it again: the prompt only appears when they tap the update button, so
they can still play. Installing the latest build by hand gets them the update.

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

The history scrolls sooner than the update prompt does, at 300 pixels, so even
a long one opens as a compact dialog.

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

"Everywhere" means the manifest carries a content pack under every platform key
this pipeline builds for — `android`, `windows`, `linux` and `macos` — because the
launcher looks the pack up by that exact key and has no fallback. Two packs cover
the four: mobile and desktop need different texture compression, but the Windows,
Linux and macOS presets all produce a byte-identical pack (while they share their
`texture_format/*` flags and `custom_features`), so one desktop pack is published
under all three desktop keys.

That is the set this pipeline builds, not the set the launcher can ask for.
`platform_key()` ends in `_: return OS.get_name().to_lower()`, so a target nobody
here exports — `ios`, `visionos`, or `web` — produces a key with no entry in the
manifest, and the update check settles on `UNAVAILABLE` with
`No content pack published for <key>.`

A Web export needs no pack, since it updates by being re-served — but the launcher
does not know that, and will show that message from the first release onward.
There is one config for every platform, so turn `show_update_bar` and
`check_on_launch` off for a web build from `_launcher_opening()`, which runs
before the launcher reads them, until the launcher learns to skip the check
there:

```gdscript
if OS.has_feature("web"):
    BuildInfo.config.check_on_launch = false
    BuildInfo.config.show_update_bar = false
```

### What a binary update cannot do off Android and Windows

`_apply_binary()` swaps the APK on Android and the `.exe` on Windows. There is no
equivalent for Linux or macOS, so those platforms carry no `binary` entry in the
manifest, and nothing in CI will ever publish one.

A release that raises `binary_version` therefore ends on `UNAVAILABLE` there, but the
app does not pretend CI is behind. `UpdateService.manual_download_needed` is set,
the status bar reads "Version X needs a new build for linux. Open the releases page
to download it.", and the button reads **"Open releases page"** and opens it
(`UpdateService.open_releases_page()`). If the config cannot name a release page,
the button falls back to re-checking.

The releases page only helps if there is something on it: CI publishes no Linux or
macOS binary, so a game that ships on those platforms has to attach its own build to
the release by hand.

Which platforms get this treatment is `UpdateService.MANUAL_BINARY_PLATFORMS`. On Android
and Windows a missing `binary` entry still means CI has not built it yet, and keeps the
"none is published for <platform> yet" wording.

`apply_pending_update()` still returns immediately while `pending_artifact` is empty, and the
`shell_open` fallback at the end of `_apply_binary()` stays reachable only when a manifest
carries an entry for the platform: that guard protects the "no artifact, no
install" invariant, so the release-page path does not go through it.

Most releases do not need a new binary: `binary_version` is bumped by hand and
only for a change a content pack cannot deliver, such as an engine upgrade, a new
permission, or a new plugin.

## Signing

**Android will not install an update over an app signed with a different key.**
Stable signing is therefore what makes self-update work at all, not a detail.

The release workflow uses, in order of preference:

1. **A release keystore from repository secrets.** The intended setup.
2. **A CI-generated debug key**, kept alive in the Actions cache under a fixed
   key so the signature stays stable between runs. This exists so the pipeline
   produces an installable APK before anyone configures signing. Actions caches
   are evicted after 7 days without a hit; if that happens a new key is generated
   and already-installed copies can no longer be updated in place. Its password
   is the public string `android`, and a cache on the default branch can be restored by
   workflows that run for pull requests from forks. On a public repository, where
   anyone can open such a pull request, treat that key as readable by anyone.
   (`ci.yml` does not restore this cache; the exposure is a pull request that adds a
   step doing so, which is separate from the release keystore below.) That is
   acceptable for a throwaway fallback, but not for an app you cannot afford to
   have an attacker update in place: set a release keystore before you publish one.

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

- The workflow only runs on `push` to `main` or `dev` and manual dispatch. Pull requests
  go through `ci.yml`, which has no secrets and publishes nothing — so a fork PR
  can never reach the key. It does rehearse the end of the release: `ci/release_dry_run.sh`
  runs the assemble and manifest steps of `release.yml` itself, checks the manifest against the
  files, and runs `publish_release.sh` against a stand-in for `gh`, so a broken release path
  fails the pull request rather than the first merge. Whether GitHub accepts the upload is
  the one thing it cannot show.
  The rehearsal finds the release steps by name ("Assemble release directory", "Build update
  manifest") and expects the release directory to be `build/release`; it runs them with `bash -euo
  pipefail` and the `steps.version.outputs.*` values as environment variables, and ignores a step's own `env:`,
  `working-directory:`, `shell:` and `if:`. A game that renames those steps or moves the directory
  should remove the "Rehearse the release assembly" step from its own `ci.yml` (workflows are the
  game's, `ci/` is overwritten by the sync). The unit tests that read the workflows only apply
  to the template itself and are skipped in a game.
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
the release tagged `v<version_name>+<content_version>`, here or in the
[releases repository](#publishing-from-a-private-repository) `RELEASE_REPO` names.

`version_name` has to start with an ASCII letter or digit and use only ASCII letters, digits, `.`, `_` and `-`,
with no `..`. It ends up in the tag, in `export_presets.cfg`, in a GDScript constant and in a shell
step, so `ci/prepare_build.sh` refuses anything else before it writes a file, rather than corrupting one or
failing at the publish step. The list is stricter than git requires: some refused names (an accent, `@`, `#`)
would make a valid tag. A `+` is refused because it separates the name from the content version in
the tag, and the patch-note collection splits tags on it.

Bump `binary_version` in `version.json` in the same commit if the change needs a
new binary. If you forget, players on the old binary will download a content pack
that cannot actually deliver the change — bump it and merge again to correct.

A `binary_version` bump is the one change worth putting on a device first, since
installing over the top is the part no local test covers. See
[Trying a change on a device before it ships](#trying-a-change-on-a-device-before-it-ships).

## Publishing from a private repository

The app downloads its updates with no token, so the releases it reads have to be
public. A token in the app is not an answer: anyone can pull it out of the APK, a
token that can read a private repository's releases can read all of its code,
and when it expires every installed copy stops updating for good.

So a game whose code is private publishes its releases to a second, **public
repository that holds only releases**. The code stays private, players need
nothing, and the token that publishes lives only in the game's Actions secrets.

First, bring the game's `.github/workflows/` up to date with the template's (see
[the sync's drift note](TROUBLESHOOTING.md#the-sync-says-my-workflows-have-drifted)):
a `release.yml` from before this existed ignores `RELEASE_REPO` and goes on
publishing here. A build that checks one repository for updates but is published
to another says so in a warning.

1. **Create the releases repository**, public, for example `you/your-game-releases`.
   Tick *Add a README*: GitHub cannot create a release tag in a repository with no
   commits.
2. **Create a token** that can publish there: a fine-grained personal access
   token, with *Repository access* set to that one repository and *Contents* set to
   *Read and write*. A classic token is refused: it reaches every repository you
   can, your private source included. Treat this one like the signing key, since
   it can ship code to every player: give it an expiry, and replace it when
   someone with access to the secrets leaves. When it expires, releases stop
   publishing until you replace it; installed copies are not affected.
3. **In the game's repository**, under *Settings → Secrets and variables →
   Actions*: add the token as the secret `RELEASE_TOKEN`, and the releases
   repository's `owner/name` as the variable `RELEASE_REPO`.
4. **Point the app at it:** set `update_repo` in `launcher_config.tres` to the
   releases repository.

The release workflow then publishes there: the release, its tag, its assets and
every link in its notes. Its first step checks the setup before anything is built,
and fails in seconds with the fix when the token is missing or classic, or the
releases repository does not exist, is private or is empty. It cannot tell
whether the token may write there, since any token can read a public repository:
a token given the wrong repository fails at the publish step. Pull-request
checks read `RELEASE_REPO` too, and need no token for a public repository.

What becomes public is what a release carries: the version numbers, the patch
notes, which are the commit subjects of the branch the release ran on, that
branch's name for a branch build, and the short commit hash each build came
from. The exported game is published too, and a Godot pack decompiles back to
its scripts, so nothing secret belongs in the project.

### Moving a game that has already shipped

Installed copies poll the `update_repo` they were built with, so they have to be
told about the new repository while the old one is still public. A content update
is enough: the launcher reads its config after mounting the content pack.

1. Set up the releases repository and `RELEASE_TOKEN` as above, but do not set
   `RELEASE_REPO` yet.
2. Set `update_repo` to the releases repository and merge. That release is still
   published here, where every installed copy looks, and once a copy has it, it
   polls the releases repository. Its build warns that it checks one repository
   and is published to another: for this one release, that is the point.
3. Straight away, set `RELEASE_REPO`, then run the release again on the same
   commit (*Actions → Release → Run workflow*), so the releases repository holds
   that release too, with the changelog players already have. Until it has run, a
   copy that took step 2's release finds no release to check. It reads that
   changelog from this repository's latest release, so run it while this
   repository is still public.
4. Make the code repository private only once players have had time to update.
   A copy that never fetched step 2's release keeps polling here, and stops
   updating the moment this repository goes private.

## Running the workflows on your own machine

Actions minutes are charged on a private repository, so a game may run its jobs
on a [self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners)
instead. Two repository variables pick the runner, with no edit to the workflows,
which would otherwise show up as drift on every launcher sync:

| Variable | Jobs | Unset |
|---|---|---|
| `CI_RUNNER` | the pull-request checks (`ci.yml`, `launcher-version.yml`) | `ubuntu-latest` |
| `RELEASE_RUNNER` | the release (`release.yml`) | `ubuntu-latest` |

Each takes one runner label, and both are ignored on a public repository.
**Never register a self-hosted runner on a public repository.** A pull request
runs the workflow file from the pull request, so anyone who can open one can
name your runner's label in it and run code there. The workflows send a fork's
pull request to `ubuntu-latest`, but that only keeps an unmodified workflow off
your runner; it is not a security boundary. On a private repository, keep
*Run workflows from fork pull requests* turned off.

The launcher sync, and the pull request it opens, always run on `ubuntu-latest`:
they run scripts just pulled from the template, before you have reviewed them.

The machine needs Linux on x86_64, bash 4, git, Python 3, curl, unzip and `gh`. The
workflows install Java, the Android SDK and Godot themselves, and keep Godot in
the runner's home between jobs. The boot check and the GDScript tests run with
a scratch home, so `user://` starts empty on every run, as it does on GitHub's
machines. `shellcheck` is installed with `sudo apt-get` only when it is missing.

A pull request's code runs on `CI_RUNNER` before anyone reviews it, and
anything it leaves on the machine runs in the next job there: in the Godot
install, the JDK or Android SDK, the workspace's `.git`, or a process still
running. So:

- **Keep the release off the CI machine.** The safest `RELEASE_RUNNER` is none.
  If you set one, give it a different machine, or at least a different OS user
  with its own home and its own runner registration, and give each runner a
  label of its own rather than just `self-hosted`. A release job holds the
  signing keystore, its password and `RELEASE_TOKEN`, and the release step warns
  when it runs on a self-hosted runner.
- **Run the runner as a dedicated user**, never your own account. The workflows
  replace `~/godot` and Godot's export templates, and overwrite Godot's editor
  settings, in that user's home.
- **Do not give that user sudo.** Install `shellcheck` yourself.
- **Prefer ephemeral runners**, which start clean for every job
  (`./config.sh --ephemeral`, or a VM or container reset after each one).

Uploading to GitHub's release storage can also be far slower from your machine
than from GitHub's. Measured once from one self-hosted runner, a 245 MB release
took 22 minutes to upload, against 8 seconds from GitHub's machines.

## Trying a change on a device before it ships

Merging to `main` publishes to everyone, and a pull request's CI artifact is no
substitute: it is signed with a key made fresh for each run, so Android refuses
to install it over the real app, and installed beside it, it would never update.

A **branch build** fixes that. It follows one branch's rolling prerelease instead
of `/releases/latest/`, so a change reaches a real device — over the real update
path, binary updates included — before any player sees it.

### Setting one up

1. **Add the branch to the release workflow.** `.github/workflows/release.yml`
   already lists `dev`; rename it or add your own:

   ```yaml
   on:
     push:
       branches: [main, dev]
   ```

   A push to any branch that is not the repository's **default** branch publishes
   a **prerelease** tagged `branch-<name>`, refreshed in place on every push.
   GitHub defines the latest release as the newest one that is neither a
   prerelease nor a draft, so `/releases/latest/` never returns it.

   The workflow compares against the repository's real default branch, not the
   literal `main`, so renaming your release branch needs no second edit here.

   Workflows are not synced from the template, so this step is yours to copy —
   everything below comes from `ci/` and `addons/launcher/`, which are.

2. **That is the whole setup.** There is no launcher setting to turn on. A build
   follows a branch because it was *exported* for that branch: CI passes
   `RELEASE_BRANCH` to `ci/prepare_build.sh`, which stamps it into the binary, and
   that one value decides the Android package id, the `user://` directory, the
   menu stamp, and which release the app polls.

   Building one by hand is the same thing:

   ```bash
   RELEASE_BRANCH=dev bash ci/prepare_build.sh
   ```

   Deliberately *not* a field on `LauncherConfig`. A setting there would travel
   with the merge that ships the change — the last step below — and point every
   player's app at the prerelease. It would also be overridable by a content
   pack, since the config is loaded after a pack is mounted, while the build
   stamp is fixed before any pack exists.

The branch name is used verbatim as the tag suffix and as one URL path segment,
so it must be letters, digits, dot, underscore and hyphen, starting with a letter
or digit. `prepare_build.sh` refuses anything else rather than building something
that cannot poll itself, and the launcher applies the same rule.

### What makes it a separate app

A branch build has to sit *next to* the released app, not replace it. Three things
give it its own identity, all applied by `prepare_build.sh` and only when
`RELEASE_BRANCH` is set:

| | |
|---|---|
| Android package id | gains a `.<branch>` segment, so Android treats it as a different app — without this the branch APK replaces the player's app, and the next release APK, signed with the same key, replaces it straight back |
| App name | gains a `(<branch>)` label, so two icons on one home screen are tellable apart |
| `user://` | a custom user dir, so neither app reads the other's saves, settings, or `update_state.json` — which names the content pack to mount, and would otherwise have the released app boot the branch's content |

On Android the package id already separates private storage; the custom user dir
is what separates everything else. As a second line of defence, the launcher
records which stream staged a content pack and refuses to mount one staged by a
differently-stamped binary — so two builds that somehow *did* share a `user://`
still would not boot each other's content.

The menu stamp leads with `branch dev · …` so a build on a device says which one
it is.

### Using it

Merge the change into the branch. The workflow publishes, and the branch build
picks it up on its next launch — including a `binary_version` bump, which
exercises the real install-over-the-top update that only a device can prove
works. Once it plays right, merge to `main` and it ships.

Versions stay monotonic as long as the branch only moves forward: `content_version`
is `git rev-list --count HEAD`, so merging into the branch always raises it.
Resetting or force-pushing the branch can lower it, and a build will then refuse
to "update" backwards.

## Testing the update path

The fastest loop, without touching a phone:

1. Run the project from the editor. It reports version `0`/`0`, so any published
   release looks newer and the menu offers the update immediately.
2. To test content updates specifically, publish a release, then run a build
   whose `content_version` is lower than the published one.
3. `user://` is `%APPDATA%\Godot\app_userdata\the game` on Windows. Delete
   `update_state.json` and `content/` there to reset a machine to stock content.
