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

- **Self-updating builds.** Content packs reach every platform this pipeline
  builds for — Android, Windows, Linux and macOS. A new *binary* installs itself
  on Android, which swaps the APK in place, and on Windows, which swaps its own
  `.exe`; Linux and macOS take content packs only, and say so plainly when a
  release needs a new binary. Every download is checked against a SHA-256 before
  it is installed.
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
rm -rf /tmp/lt && git clone --depth 1 https://github.com/sinikebe/godot-launcher-template /tmp/lt
mkdir -p addons .github/workflows
cp -R /tmp/lt/addons/launcher addons/
cp -R /tmp/lt/ci .
cp /tmp/lt/build_version.gd /tmp/lt/build_version.gd.uid /tmp/lt/version.json /tmp/lt/launcher_config.tres .
cp -R /tmp/lt/.github/workflows/. .github/workflows/
cat >> .gitignore <<'EOF'

# Build output, Godot's import cache, and Android signing material, which must
# never be committed.
/build/
.godot/
*.keystore
*.jks
*.p12
*.idsig
EOF
```

The copy overwrites any workflow of yours with the same name, and every sync
replaces `ci/` and `addons/launcher/` wholesale, so move any files of your own
out of those first.

**Export presets.** The workflows export by preset name. Your committed
`export_presets.cfg` needs one preset called exactly `Android` and one called
exactly `Windows Desktop`. A game with no presets yet can take the template's:

```bash
cp /tmp/lt/template/export_presets.cfg .
```

If yours has presets already, keep the file and add or rename those two, but
give them the settings the pipeline relies on, as the template's file does.
Godot's defaults for a new preset leave them off, and CI stays green without
them:

- `Android`: `permissions/internet=true`, and
  `android.permission.REQUEST_INSTALL_PACKAGES` in
  `permissions/custom_permissions`. Without the first the app cannot check
  for updates, and without the second it cannot install one.
- `Windows Desktop`: `binary_format/embed_pck=true`. The release publishes
  the `.exe` alone, so a build that keeps its data in a separate `.pck` ships
  without it.

Copying the template's file over yours would replace your own settings.

Then in `project.godot`, register the autoloads **in this order** and point at
your config:

```ini
[autoload]
BuildInfo="*res://addons/launcher/build_info.gd"
UpdateService="*res://addons/launcher/update_service.gd"

[launcher]
config_path="res://launcher_config.tres"

[rendering]
textures/vram_compression/import_etc2_astc=true
```

`BuildInfo` must come first — it mounts content packs before anything loads a
scene out of `res://`. The last line turns on the texture format Android
needs; without it, the release's Android export fails. Set the main scene to
`res://addons/launcher/launcher.tscn`.

Last, give it your game's identity. `ci/new_game.sh` does this only for a
repository made from the template, and it does nothing here, so edit the
copies by hand before your first release:

- **`launcher_config.tres`**: set `update_repo` to your game's own
  `owner/name`. Left as the template's, your game checks the template's
  releases for updates, and can be offered the demo's content pack as one.
  Set `play_scene` to the scene that used to be your main scene, or Play has
  nothing to start. Set `game_title` and `tagline`, and clear `extra_buttons`
  unless you want the demo's Settings button.
- **`version.json`**: set `game_name`. The APK, the `.exe` and the release are
  all named from it.
- **`export_presets.cfg`**, if it came from the template: set
  `package/unique_name` to your own Android package id, and
  `package/name`, `application/product_name` and
  `application/file_description` to your game's name. Two apps with the same
  package id cannot both be installed on one device.

Then commit, push, and enable *Settings → Actions → General → Allow GitHub
Actions to create and approve pull requests*. Releases are built from pushes
to `main`; if your default branch has another name, rename it to `main` on
GitHub. Editing the workflow instead would be undone the next time you copy
the template's workflows across. [Set up Android
signing](docs/GETTING-STARTED.md#android-set-up-signing-before-you-share-it)
before other people install it.

## Making it yours

Everything below is a field on your `LauncherConfig`, apart from one optional
script for running code of your own. **Nothing in `addons/launcher/` should
ever need editing** — that directory is replaced wholesale on every sync, so
local edits there are silently reverted.

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
touching the launcher. Connect it from `_launcher_opening()` in
`res://launcher_hooks.gd` — see
[Your own code on the launcher's screen](#your-own-code-on-the-launchers-screen):

```gdscript
func _launcher_opening(launcher: Control) -> void:
    launcher.custom_button_pressed.connect(func(label: String) -> void:
        if label == "Settings":
            launcher.get_tree().change_scene_to_file("res://settings.tscn"))
```

`play_scene` is what Play loads. Leave it empty and Play says so instead of
failing silently — unless you connect `play_requested` the same way, which with
`play_scene` empty takes the Play action over entirely.

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
the default dark-green one. One thing it cannot style is a panel around the
update dialog's text: the dialog's own `PanelContainer` panel is its frame, so
the text area ignores the theme's `ScrollContainer` panel.

### Your own code on the launcher's screen

The launcher is the main scene, so unless you have added an autoload, none of
your code runs while it is showing. To run some, create
**`res://launcher_hooks.gd`** with a `_launcher_opening()` function. The
launcher looks for that file and calls the function each time it opens: at
launch, and again whenever your game returns to it. That happens after any
content pack has been mounted and before the launcher builds anything, so
whatever it sets up is in force on the first frame.

```gdscript
# res://launcher_hooks.gd
func _launcher_opening(launcher: Control) -> void:
    launcher.register_translations(["res://locale/"])

    var settings := ConfigFile.new()
    if settings.load("user://settings.cfg") == OK:
        TranslationServer.set_locale(settings.get_value("game", "language", OS.get_locale()))

    launcher.custom_button_pressed.connect(func(label: String) -> void:
        if label == "Settings":
            launcher.get_tree().change_scene_to_file("res://settings.tscn"))
```

**Content updates can change it.** The file is yours and lives outside the
directories the sync replaces. It ships in content packs like any other script,
and the launcher that runs it is the content pack's own, so changing it never
needs a new app build — even on app builds made before this file existed.
Adding an autoload, or a scene of yours around the launcher, means changing
project settings, which a content pack cannot do.

Things to watch:

- **It runs against every app build your players still have.** `BuildInfo`
  and its `config` belong to the installed app, so a member newer than your
  oldest build is not there on older devices: test for it by name
  (`"field" in BuildInfo.config`, `has_method()`) instead of reading it outright.
- **Don't `await` in it.** The launcher builds its screen as soon as the
  function returns.
- **A broken file costs what it sets up, and nothing more.** If it fails to
  parse, the launcher logs `launcher_hooks.gd could not be loaded; carrying on
  without it` and runs without it: no catalogs registered, no buttons wired,
  and with `play_scene` empty no Play. Updates keep working, so the next content
  update can repair it. The CI boot check does not fail on this (#71), so look
  for that line before you ship. An error while the function runs stops the
  rest of the function, and nothing else.
- **Once an app build has shipped the file, keep it.** A content update can
  replace the file but never remove it. Delete it from the project and devices
  carry on running the copy their app build shipped. To retire it, ship one
  that does nothing.

### Language

The launcher's own screens translate through Godot's usual gettext support. It
ships a template of its strings at
[`addons/launcher/launcher.pot`](addons/launcher/launcher.pot) — 71 of them,
generated by `ci/make_pot.py`.

1. Copy the `.pot` to a `.po` per language, translate the `msgstr` lines, and
   **set the `Language:` header** to that language's code (`Language: fr`).
   Godot reads the locale from that header, not from the filename: a `.po` that
   leaves it empty translates nothing, and one that drops the line altogether is
   loaded under your project's own locale and then shown to *every* player,
   English included. Set `Plural-Forms:` to the language's rule too — the
   template ships the English one.
2. Put them in **`res://locale/`**, not in `addons/launcher/` and not in `ci/`.
   Those two directories are replaced wholesale on every launcher sync, so a
   `.po` left inside either is deleted without warning.
3. **Register them from `_launcher_opening()` in `res://launcher_hooks.gd`**,
   with `launcher.register_translations(["res://locale/"])` — see
   [Your own code on the launcher's screen](#your-own-code-on-the-launchers-screen).
   Don't use Project Settings → Localization. Godot reads that list from the
   installed app at startup, before the launcher mounts a content pack, so a
   catalog listed there only changes with a new app build. A corrected string,
   or a whole new language, shipped as a content update would never be read.
   `register_translations()` reads what `res://` holds right now, content pack
   included. A catalog the app already loaded from Project Settings **at the
   same path** is replaced by the pack's copy, so a game that registered its
   catalogs there before gets content updates to them too.

   **Keep each catalog's path and file name the same from release to
   release.** A content update can replace a file but never remove one, so a
   catalog that is moved, renamed or converted to another format leaves its
   old copy in the installed app. That copy is still registered, from Project
   Settings or because you passed its folder, and its old strings can win over
   the new ones. If you must rename a catalog, pass the files by name instead
   of the folder, and drop the old path from Project Settings in your next app
   build.

Godot picks the language from the device. To let players choose their own,
call `TranslationServer.set_locale()` from `_launcher_opening()` as well, with
the language they saved, so the first screen is already in it. The launcher's
screen also follows a language change while it is showing, such as one made
in a settings panel drawn over it. An update error already on screen keeps its
language until the next update check, which runs each time the launcher opens
while `check_on_launch` is on.

Two limits worth knowing before you translate. The bundled theme uses Godot's
built-in font, which covers Latin, Latin-Extended, Cyrillic, Greek and Hebrew —
Arabic, CJK, Korean, Thai and Indic text renders as blank boxes. For those,
supply a theme through `theme_override` whose `default_font` has the glyphs, or
add a `SystemFont` to that font's `fallbacks`. And `game_title` is drawn on one
line without wrapping: a title around 28 capitals wide reaches the screen edge
at the default size, so check a long translation rather than assuming it fits.

Your own strings — `game_title`, `play_text`, `quit_text`, `tagline` and each
entry of `extra_buttons` — belong in your `.po` alongside the launcher's, keyed
on the English text you wrote. A `tagline` is keyed on the value **as written**,
`{build}` and `{version}` placeholders included: the launcher translates the
template and fills the placeholders afterwards.

> Two cautions worth passing to a translator. A `msgid` with more than one
> placeholder carries a note in the `.pot`: reorder with indexed forms
> (`%1$s`, `%2$d`), because swapping a bare `%s` and `%d` is a runtime error
> rather than a typo. And because a content update can ship new launcher code,
> rewording an English string upstream retires its `msgid` — re-merge the `.pot`
> after a launcher update, the same as for any gettext project.

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
| [How updates work](docs/UPDATES.md) | The two version numbers, the manifest, signing, per-platform behaviour, trying a change on a device before it ships |

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
