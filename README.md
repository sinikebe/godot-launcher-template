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

```bash
git clone https://github.com/sinikebe/godot-launcher-template
godot --path godot-launcher-template
```

The repo is a runnable Godot project: `addons/launcher/` is the reusable part,
and the rest is a demo harness for developing it.

## Install it into a game

1. **Copy the launcher in.**

   ```bash
   cd your-game
   git clone --depth 1 https://github.com/sinikebe/godot-launcher-template /tmp/lt
   cp -R /tmp/lt/addons/launcher addons/launcher
   cp -R /tmp/lt/ci ci
   cp /tmp/lt/build_version.gd build_version.gd
   cp /tmp/lt/version.json version.json
   cp -R /tmp/lt/template/.github/workflows/. .github/workflows/
   ```

2. **Register the autoloads**, in this order, and point at your config — in
   `project.godot`:

   ```ini
   [autoload]
   BuildInfo="*res://addons/launcher/build_info.gd"
   UpdateService="*res://addons/launcher/update_service.gd"

   [launcher]
   config_path="res://launcher_config.tres"
   ```

   `BuildInfo` **must come first**: it mounts content packs before anything
   loads a scene out of `res://`.

3. **Make a `LauncherConfig`.** In the editor: right-click → New Resource →
   `LauncherConfig`, save as `res://launcher_config.tres`. Set `update_repo` to
   your game's own `owner/name` on GitHub.

4. **Set the main scene** to `res://addons/launcher/launcher.tscn`.

5. **Merge to `main`.** The release workflow does the rest.

For Android you also need signing secrets — see
[docs/UPDATES.md](docs/UPDATES.md#signing). Without them CI falls back to a
throwaway debug key, which builds fine but cannot self-update reliably.

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

### Look

`theme_override` replaces the bundled theme wholesale. Leave it empty to keep
the default dark-green one.

## Keeping games up to date with the template

`template/.github/workflows/sync-launcher.yml` runs daily in each game, pulls
`addons/launcher/` and `ci/` from this repo, imports and boots the project to
prove it still loads, and opens a pull request if anything changed.

It opens a PR rather than pushing, because merging `main` in a consuming game
publishes a release — a launcher change should not reach players unlooked-at.
To make it fully hands-off, turn on auto-merge for that PR in the game's repo
settings.

The synced revision is recorded in `addons/launcher/.launcher-sync.json`.

A token scoped to `contents` is not allowed to write `.github/workflows/`, so the
starter workflows are **not** synced. When they change upstream the sync says so
in the pull request body, and you copy them across by hand.

> A pull request opened with `GITHUB_TOKEN` does not trigger other workflows, so
> the sync job runs the import-and-boot check itself before opening the PR. If
> you want the game's full CI on it as well, give the workflow a PAT instead.

## Layout

| Path | |
|---|---|
| `addons/launcher/` | **The launcher.** Synced into games; never edit downstream |
| `addons/launcher/launcher_config.gd` | Every knob, documented inline |
| `ci/` | Build and release scripts. Also synced |
| `template/` | Starter files a game copies **once**: workflows and export presets |
| `docs/UPDATES.md` | How updating actually works, and how to sign Android builds |
| `build_version.gd`, `launcher_config.tres`, `project.godot` | The demo harness |

## Requirements

Godot **4.7**, no C#, no addons. Android builds need the SDK in CI (the supplied
workflow sets it up) and a signing keystore for real self-update.
