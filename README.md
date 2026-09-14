# Godot Launcher Template

A drop-in main menu for Godot 4.7 games that **keeps the game up to date by
itself** — on Android it installs a new APK in place, everywhere else it pulls a
content pack and restarts.

Skin it from one resource file. Pull launcher improvements into every game you
own with a scheduled job.

```
┌──────────────────────────────────────────┐
│  YOUR GAME                               │   title      ← placeable
│  build 12 · updates itself               │   tagline
│                                          │
│                 ┌──────────────┐         │
│                 │     Play     │         │   menu       ← placeable
│                 │   Settings   │         │              ← your own buttons
│                 │     Quit     │         │
│                 └──────────────┘         │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │ Up to date.    What's new │ Check ▸  │ │   update bar
│ └──────────────────────────────────────┘ │
│                  v1.2.0 · bin 2 · content 12
└──────────────────────────────────────────┘
```

## What you get

- **Self-updating builds.** Android APKs install over themselves; Windows swaps
  its own `.exe`; everything else takes content packs. Every download is checked
  against a SHA-256 before it is installed.
- **Two update tracks.** A `.pck` content update is tens of kilobytes and applies
  on restart. Only genuine binary changes — engine version, permissions, plugins —
  need a full APK.
- **Patch notes**, generated from your commit subjects, shown before the download
  and readable at any time, including offline.
- **A release pipeline.** One merge to `main` builds the APK, the Windows `.exe`
  and both content packs, then publishes them with the manifest the app polls.

## Try it

Install the demo and watch it update itself before you commit to anything:

| | |
|---|---|
| Android | [**launcher-demo.apk**](https://github.com/sinikebe/godot-launcher-template/releases/latest/download/launcher-demo.apk) |
| Windows | [**LauncherDemo.exe**](https://github.com/sinikebe/godot-launcher-template/releases/latest/download/LauncherDemo.exe) |

It is this repository, built by the same workflows a game gets, polling this
repository for its own updates. Whatever it does there, your game will do.

Or run it from source:

```bash
git clone https://github.com/sinikebe/godot-launcher-template
godot --path godot-launcher-template
```

## Start a new game

**[→ Getting started](docs/GETTING-STARTED.md)** walks through it end to end,
with what you should see at each step. The short version:

1. **Use this template** → create your repository → clone it.
2. Name it, in one command:

   ```bash
   bash ci/new_game.sh "Deep Cavern" com.yourname.deepcavern
   ```

3. Commit, push, and enable *Settings → Actions → General → Allow GitHub
   Actions to create and approve pull requests*.

That is it. The first push builds an APK, a Windows `.exe` and the update
manifest, and publishes them as a release.

Before other people install it, [set up Android
signing](docs/GETTING-STARTED.md#android-set-up-signing-before-you-share-it) —
changing the key afterwards forces everyone to uninstall first.

## Add it to an existing game

```bash
cd your-game
git clone --depth 1 https://github.com/sinikebe/godot-launcher-template /tmp/lt
cp -R /tmp/lt/addons/launcher addons/launcher
cp -R /tmp/lt/ci ci
cp /tmp/lt/build_version.gd /tmp/lt/version.json /tmp/lt/launcher_config.tres .
cp -R /tmp/lt/.github/workflows/. .github/workflows/
cp /tmp/lt/template/export_presets.cfg .   # merge with yours if you have one
```

Then in `project.godot`, register the autoloads **in this order** and point at
your config:

```ini
[autoload]
BuildInfo="*res://addons/launcher/build_info.gd"
UpdateService="*res://addons/launcher/update_service.gd"

[launcher]
config_path="res://launcher_config.tres"
```

`BuildInfo` must come first — it mounts content packs before anything loads a
scene out of `res://`. Set the main scene to
`res://addons/launcher/launcher.tscn`, then follow steps 2 and 3 above.

## Making it yours

Everything below is a field on your `LauncherConfig`. **Nothing in
`addons/launcher/` should ever need editing** — that directory is replaced
wholesale on every sync, so local edits there are silently reverted.

### Identity

| Field | |
|---|---|
| `game_title` | The big text |
| `tagline` | Line underneath. `{build}` and `{version}` are filled in at runtime; empty hides it |

### Background

| Field | |
|---|---|
| `background_texture` | Your image. Wins over the shader when set |
| `background_shader` | Used when there is no texture. Ships with an organic default |
| `background_color` | Flat fill behind both, and the whole background if neither is set |
| `background_stretch` | Scale / Tile / Keep Centered / **Cover** / Contain |
| `background_dim` | 0–1 black veil. Raise it when a busy photo fights the text |

### Placement

The title block and the menu are positioned independently, each by a
horizontal and a vertical alignment, so either can go in any of nine spots.

| Field | |
|---|---|
| `title_h_align` / `title_v_align` | Left·Center·Right × Top·Center·Bottom |
| `menu_h_align` / `menu_v_align` | Same, for the buttons |
| `menu_orientation` | Vertical or Horizontal |
| `menu_width` | Button column width (vertical only) |
| `menu_separation` | Gap between buttons |
| `edge_margin` | Distance from the screen edge, for everything |

### Buttons

`show_play` / `play_text`, `show_quit` / `quit_text`, and `extra_buttons` — a
list of labels inserted between them. Pressing one emits
`custom_button_pressed(label)`, so a game adds Settings or Credits without
touching the launcher:

```gdscript
func _ready() -> void:
    var launcher := $Launcher
    launcher.custom_button_pressed.connect(func(label: String) -> void:
        if label == "Settings":
            $SettingsPanel.show())
```

`play_scene` is what Play loads. Leave it empty and Play says so instead of
failing silently; connect `play_requested` to take the action over entirely.

### Version stamp

The corner of the launcher shows two lines: the game's version on top, and the
launcher's underneath. The semver comes from the template, the short hash is the
template commit the game synced:

```
v0.2.0  ·  bin 2  ·  content 13  ·  6721df5d
launcher 2.1.0  ·  b0f419d7
```

Inside the template and in a hand-vendored copy there is no synced commit, so
the second line is just `launcher 2.1.0`. It is the first thing worth asking for
in a launcher bug report.

`VERSION` is hand-maintained, and `ci/check_launcher_version.sh` fails a pull
request that changes `addons/launcher/` without moving it — label the pull
request `no-launcher-bump` for a change that genuinely does not warrant one.

### Look

`theme_override` replaces the bundled theme wholesale. Leave it empty to keep
the default dark-green one.

## Keeping games up to date with the template

`.github/workflows/sync-launcher.yml` runs daily in each game, pulls
`addons/launcher/` and `ci/` from this repo, imports and boots the project to
prove it still loads, and opens a pull request if anything changed.

**It opens a pull request and stops there. It never merges.** Merging `main` in
a consuming game publishes a release to players, so deciding that a launcher
change is safe to ship is the game developer's call, not the robot's. The
workflow contains no merge step, and nothing in this template asks you to turn
on auto-merge.

Review the diff, then merge it yourself.

The synced revision is recorded in `addons/launcher/.launcher-sync.json`.

A token scoped to `contents` is not allowed to write `.github/workflows/`, so the
starter workflows are **not** synced. When they change upstream -- or when the
template adds one you do not have -- the sync says so in the run summary of every
sync run, and in the pull request body when one is opened. You copy them across
by hand.

> A pull request opened with `GITHUB_TOKEN` does not trigger other workflows, so
> the sync job runs the import-and-boot check itself before opening the PR. If
> you want the game's full CI on it as well, give the workflow a PAT instead.

## Layout

| Path | |
|---|---|
| `addons/launcher/` | **The launcher.** Synced into games; never edit downstream |
| `addons/launcher/launcher_config.gd` | Every knob, documented inline |
| `addons/launcher/launcher_version.gd` | The launcher's own version; CI fails a launcher change that does not bump `VERSION` |
| `ci/` | Build and release scripts. Also synced |
| `template/` | The one starter file a game copies **once**: `export_presets.cfg` |
| `.github/workflows/` | The template's own CI — and exactly what a game gets |
| `docs/GETTING-STARTED.md` | **Start here.** Zero to a self-updating release |
| `docs/TROUBLESHOOTING.md` | Symptoms, and what each one means |
| `docs/UPDATES.md` | How updating actually works, in depth |
| `build_version.gd`, `launcher_config.tres`, `project.godot` | The demo harness |
| `LICENSE` | MIT. Copies also live in `addons/launcher/` and `ci/`, so the terms travel with the synced code |

## Does this need anything from me?

No. The template is public, and a game syncs from it with an anonymous clone —
no token, no account, no permission. Fork it if you would rather not depend on
this repo moving under you, and point `LAUNCHER_TEMPLATE_REPO` in the sync
workflow at your fork.

Nothing is shared between games that use it: each one has its own repository,
its own releases, its own Android package id and its own signing key.

## Documentation

| | |
|---|---|
| [Getting started](docs/GETTING-STARTED.md) | The walkthrough, with what you should see at each step |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | "App not installed", no pull request, updates not detected… |
| [How updates work](docs/UPDATES.md) | The two version numbers, the manifest, signing, per-platform behaviour |

## Requirements

Godot **4.7**, no C#, no addons. Android builds need the SDK in CI (the supplied
workflow sets it up) and a signing keystore for real self-update.

## License

MIT — see [LICENSE](LICENSE). Copy it into a game, ship the result commercially,
relicense your own game however you like.

Because the sync replaces `addons/launcher/` and `ci/` wholesale, each carries
its own copy of the licence, so the terms arrive with the code rather than being
left behind in a repository the game never sees. Any sync that actually runs
restores them; one that finds the template unchanged exits early and does not,
so do not delete them.

A game made from this template inherits that root `LICENSE`, which covers the
launcher and not the game. Replace it with your own. `ci/new_game.sh` says so
when it runs, and takes `--delete-licence` if you would rather start from
nothing — it will not decide for you, because no rule for telling "still the
template's" from "the developer already replaced this" is right in every case,
and guessing wrong deletes somebody's licence.

That flag applies **only while setting a game up**. Run the script in a
repository that has already been set up, or that was never a template copy at
all, and it deletes nothing and tells you to `rm LICENSE` yourself — a setup
script should not be able to remove a licence from a repository it did not
create.

MIT asks that the notice ship with substantial portions of the software, and a
built `.pck` or APK contains none of these files — the export presets ship an
empty `include_filter`, which includes only what Godot imports as a resource,
and a licence is not one. If you distribute builds, put the attribution
somewhere a player can reach: a credits screen, or a licence file beside the
executable.
