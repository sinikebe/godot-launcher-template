# Godot Launcher Template

A drop-in main menu for Godot 4.7 games that **keeps the game up to date by
itself**: it pulls a content pack and restarts, and when a release needs a new
app build, it installs the new APK in place on Android and swaps the `.exe` on
Windows.

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
│                         launcher 2.7.1
└──────────────────────────────────────────┘
```

## What you get

- **Self-updating builds.** Content packs are published for Android, Windows,
  Linux and macOS. A new *binary* installs itself on Android, which swaps the APK
  in place, and on Windows, which swaps its own `.exe`. The pipeline builds the
  app itself only for Android and Windows: if you ship on Linux or macOS, export
  those builds yourself. They take content packs, and say so plainly when a
  release needs a new binary. Every download is checked against a SHA-256 before
  it is installed.
- **Two update tracks.** A content update is a `.pck` of your game's resources
  with no engine inside, so it is far smaller than the app (the demo's is about
  80 KB, against a 50 MB APK), and it applies on restart. Only genuine binary
  changes — engine version, permissions, plugins, the icon, any `project.godot`
  setting — need a new APK or `.exe`. You mark those by bumping `binary_version`
  in `version.json`; forget, and players download a content pack that cannot
  deliver the change. See [the two version
  numbers](docs/UPDATES.md#the-two-version-numbers).
- **Patch notes**, generated from your commit subjects, shown before the download
  and readable at any time, including offline.
- **A release pipeline.** One merge to `main` builds the APK, the Windows `.exe`
  and both content packs, then publishes them with the manifest the app polls.
  See [Releasing](#releasing).
- **Branch builds.** A push to `dev` publishes a prerelease that installs beside
  the real app and updates itself from that branch, so a change reaches a device
  before any player sees it ([how](docs/UPDATES.md#trying-a-change-on-a-device-before-it-ships)).

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

1. **Use this template** → create your repository → clone it. Make it public:
   players' apps download releases with no token. A private game publishes to a
   separate public repository instead
   ([how](docs/UPDATES.md#publishing-from-a-private-repository)).
2. Name it, in one command:

   ```bash
   bash ci/new_game.sh "Deep Cavern" com.yourname.deepcavern
   ```

   It sets the name, the Android package id, and `update_repo` to your
   repository. A private game passes its public releases repository as a third
   argument, `owner/name`.
3. Replace the rest of the demo. In `launcher_config.tres`, set `play_scene` to
   your first scene, change `tagline` (it still says *template demo*), and
   clear `extra_buttons` unless you will wire up its Settings button. Replace
   `icon.svg` too: it is your app's icon, and changing it later needs a new app
   build.
4. Commit, push, and enable *Settings → Actions → General → Allow GitHub
   Actions to create and approve pull requests*.

The first push builds an APK, a Windows `.exe` and the update manifest, and
publishes them as a release.

Before other people install it, [set up Android
signing](docs/GETTING-STARTED.md#android-set-up-signing-before-you-share-it) —
changing the key afterwards forces everyone to uninstall first.

## Add it to an existing game

The copy below overwrites files of yours with the same names: workflows such
as `ci.yml`, and `version.json`, `build_version.gd` and `launcher_config.tres`
at the root. Every sync also replaces `ci/` and `addons/launcher/` wholesale.
Move anything of your own out of those first.

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
# The release exports from the committed presets.
!/export_presets.cfg
EOF
printf '\n# The launcher scripts must stay LF, or bash cannot run them.\nci/** text eol=lf\n' >> .gitattributes
```

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

Then add these to `project.godot`, merging them into sections of the same name
if you have them. The two autoloads go at the top of `[autoload]`, above any
of your own, **in this order**:

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

The launcher is laid out for the template's `[display]` settings: a 1280×720
viewport, `window/stretch/mode="canvas_items"` and
`window/stretch/aspect="expand"`. Your game keeps its own, orientation
included; see [Screen orientation](#screen-orientation).

Last, give it your game's identity. `ci/new_game.sh` does this only for a
repository made from the template, and it does nothing here, so edit the
copies by hand before your first release:

- **`launcher_config.tres`**: set `update_repo` to your game's own
  `owner/name`, or to the public releases repository a private game
  [publishes to](docs/UPDATES.md#publishing-from-a-private-repository). Left
  as the template's, your game checks the template's releases for updates,
  and can be offered the demo's content pack as one. Once the first launcher
  sync has run, it refuses instead, with `update_repo still points at the
  launcher template`.
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

There is no editor plugin to enable: the launcher is two autoloads and a
scene.

Then commit, push, and enable *Settings → Actions → General → Allow GitHub
Actions to create and approve pull requests*. If your default branch is not
`main`, see [Releasing](#releasing) first.

[Set up Android
signing](docs/GETTING-STARTED.md#android-set-up-signing-before-you-share-it)
before other people install it.

## Releasing

Every push to your default branch publishes a release. Pull requests build the
same way through `ci.yml` and publish nothing, so open one: a push straight to
`main` skips those checks.

- **Version numbers.** `content_version` is the commit count; you never set it.
  `binary_version` and `version_name` live in `version.json`. `version_name`
  goes into the release tag, so it takes ASCII letters, digits, `.`, `_` and
  `-` only.
- **Patch notes** are your commit subjects since the last release, minus merges
  and subjects starting `chore`, `ci:`, `bump `, `wip` or `revert `, at most 20
  lines. Write subjects on `main` for players; see [Patch
  notes](docs/UPDATES.md#patch-notes).
- **Branches.** Releases come from pushes to the branches listed at the top of
  `.github/workflows/release.yml`. A push to any branch there other than the
  default one (`dev`, as shipped) publishes a separate [prerelease
  build](docs/UPDATES.md#trying-a-change-on-a-device-before-it-ships). Add your
  default branch to that list if it is not `main`, and take `dev` out if your
  game uses that branch for something else. After either edit, the daily sync
  reports `release.yml` as changed upstream on every run: the difference it sees
  is your own. Copy the template's version across only when it really has
  changed, then put your edit back.

### Repository settings

These are set under *Settings → Secrets and variables → Actions*. None is a
workflow edit, so none shows up as drift on a launcher sync.

| Name | Kind | Does |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` | secrets | Your signing key ([set up](docs/GETTING-STARTED.md#android-set-up-signing-before-you-share-it)). Unset, CI uses a cached debug key |
| `RELEASE_REPO` | variable | Publish to this public `owner/name` instead ([how](docs/UPDATES.md#publishing-from-a-private-repository)) |
| `RELEASE_TOKEN` | secret | A fine-grained token that can write to `RELEASE_REPO` |
| `CI_RUNNER`, `RELEASE_RUNNER` | variables | Runner label for pull-request checks and for releases; private repositories only ([own machine](docs/UPDATES.md#running-the-workflows-on-your-own-machine)) |

## Making it yours

Most of what follows is a field on your `LauncherConfig`. The rest is code of
your own, in your game's scenes or in one optional script that runs on the
launcher's screen; your translation catalogs in `res://locale/`; two
`project.godot` settings; and the version stamp, which the launcher fills in
itself. The two settings, whether Back quits from the launcher's screen and
screen orientation, change only with a new app build, though code of yours can
override either while the app runs. **Nothing in `addons/launcher/` should
ever need editing** — that directory is replaced wholesale on every sync, so
local edits there are silently reverted.

Config changes ship in content updates: the launcher reads its config after
mounting the pack. A field that a newer launcher adds is unknown to app builds
made before it, which use its default until their next app build.

### Identity

| Field | |
|---|---|
| `game_title` | The big text |
| `tagline` | Line underneath. `{build}` becomes the content version and `{version}` the `version_name`, at runtime; empty hides it |

### Background

| Field | |
|---|---|
| `background_texture` | Your image. Wins over the shader when set |
| `background_shader` | Used when there is no texture. The template's config uses `addons/launcher/shaders/organic_background.gdshader`; a new config has none |
| `background_color` | Flat fill behind both, and the whole background if neither is set |
| `background_stretch` | Scale / Tile / Keep Centered / **Cover** / Contain |
| `background_dim` | 0–1 black veil. Raise it when a busy photo fights the text |

### Placement

The *Layout* group in the Inspector. The title block and the menu are
positioned independently, each by a horizontal and a vertical alignment, so
either can go in any of nine spots.

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
`custom_button_pressed(label)`, with the label as written in `extra_buttons`
rather than its translation, so a game adds Settings or Credits without
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
`play_scene` empty takes the Play action over entirely. `play_requested` is
emitted on every press of Play, before the scene change when `play_scene` is
set.

To come back to the launcher from your game, for a Leave or Main menu button,
change scene to it:

```gdscript
get_tree().change_scene_to_file("res://addons/launcher/launcher.tscn")
```

That path is safe to write into your game. It is the main scene of every game
set up from the template or by the steps above, and the sync never touches
your `project.godot`, so moving it would break every such game at once. The
template will not move it. If your main scene is a scene of your own around
the launcher, change to that instead. Your `_launcher_opening()` runs again
each time the launcher opens.

### Updates

| Field | |
|---|---|
| `update_repo` | `owner/name` whose releases the app checks: your game's repository, or the public one a private game [publishes to](docs/UPDATES.md#publishing-from-a-private-repository). `ci/new_game.sh` sets it. Empty turns the updater off and hides the bar |
| `check_on_launch` | Check each time the launcher opens, including each time your game returns to it |
| `show_update_bar` | The status line and its buttons along the bottom. Off hides them, not the version stamp, and a check on launch still runs, so turn `check_on_launch` off with it |

What a player sees, with `check_on_launch` on: the bar checks each time the
launcher opens. A content update reads *Content update available*; **Download
update** shows its notes, downloads, verifies and offers **Restart**. A
release that needs a new app build reads **Update app**. On Android the APK
goes to the system installer; the first time, Android sends the player to allow
installs from your game, and the button becomes **Install**. On Windows the
game downloads the new `.exe`, closes, and reopens on it, so the `.exe` has to
sit in a folder the player can write to. On Linux and macOS the button becomes
**Open releases page**. **What's new** shows every release's notes, offline
too. Errors show in the bar, and the button checks again.

A web or iOS build has nothing to fetch, and says `No content pack published
for <platform>`: turn both fields off in its config. [How updates
work](docs/UPDATES.md) has the detail.

### Back on Android

By default, Godot quits the app whenever Back is pressed. The launcher changes
that in two places only:

- **On the launcher's screen**, Back closes an open launcher dialog, and
  otherwise quits, as `application/config/quit_on_go_back` in your
  `project.godot` says (on unless you turned it off). If your
  `_launcher_opening()` adds a panel of its own, or your main scene is a scene
  of yours around the launcher, turn the quit off —
  `launcher.get_tree().quit_on_go_back = false` from `_launcher_opening()`, or
  `get_tree().quit_on_go_back = false` from that scene's `_ready()`, which runs
  after the launcher's — and handle Back by connecting the launcher's
  `back_requested` signal. It is emitted only for a Back that none of the
  launcher's dialogs took, so the Back that closes one never reaches your code
  as well. Nothing then quits on Back unless your code does. Turn it off once,
  as above, rather than switching it as your panels open and close: for the frame
  in which Back closes one of its dialogs, the launcher turns the quit off and
  then on again, which undoes a switch your code makes in that same frame.
- **In your game**, Back does nothing until you handle it, so one stray tap no
  longer ends a run. The launcher turns the quit off as it leaves the scene
  tree. To pause, open a menu or return to the launcher, handle the
  notification in your scene:

  ```gdscript
  func _notification(what: int) -> void:
      if what == NOTIFICATION_WM_GO_BACK_REQUEST:
          get_tree().change_scene_to_file("res://addons/launcher/launcher.tscn")
  ```

  To have Back quit from your game again, set
  `get_tree().quit_on_go_back = true` from your scene's `_ready()`. The
  launcher turns the quit off as it leaves the tree, which a scene change does
  after your scene is created and before its `_ready()`, so setting it any
  earlier, such as in `_init()`, is undone. A game that keeps the launcher in
  the tree, hidden, while it runs is still on the launcher's screen as far as
  Back goes: Back quits as the project setting says, and `back_requested` is
  emitted.

This is code, so a content update can change it. The project setting is not:
a content update cannot change it, and it only ever decides the launcher's
screen.

### Screen orientation

The template's `project.godot` sets `window/handheld/orientation=4`. That is
**Sensor Landscape**, not Sensor: full screen on a phone, the app turns between
the two landscape directions and never into portrait. Android's manifest gets
`userLandscape`. Full sensor, landscape or portrait, is `6` (`fullUser` in the
manifest).

Landscape is what the launcher is laid out for. With the template's
`[display]` settings it lays out on a 1280×720 base, scaled evenly until it
fills the screen one way, with any extra length the other way added to the
layout. With `6`, it still fits a portrait screen, but the 1280-wide base has
to fit the narrow side, so everything is drawn at about half the size it has
in landscape on the same phone.

Like Back, the setting is read once, at startup, so a content update cannot
change it. Code can change the orientation itself:
`DisplayServer.screen_set_orientation()`, called from your game's scenes or
from `_launcher_opening()`, changes it while the app runs, and that code ships
in a content pack like any other script. The change lasts until code changes
it again or the app restarts, so a game that turns to portrait for its own
scenes brings players back to a portrait launcher unless `_launcher_opening()`
turns it back with
`DisplayServer.screen_set_orientation(DisplayServer.SCREEN_SENSOR_LANDSCAPE)`.
Desktop builds have no orientation and log a warning for the call; guard it
with `DisplayServer.has_feature(DisplayServer.FEATURE_ORIENTATION)`.

### Version stamp

The corner of the launcher shows two lines. On top, the game:
`v<version_name> · bin <binary_version> · content <content_version> · <commit>`
([the two version numbers](docs/UPDATES.md#the-two-version-numbers)). A
[branch build](docs/UPDATES.md#trying-a-change-on-a-device-before-it-ships)
starts it with `branch <name>`. Underneath, the launcher: its semver, from the
template, and the template commit the game synced.

```
v0.2.0  ·  bin 2  ·  content 13  ·  6721df5d
launcher 2.7.1  ·  b0f419d7
```

Only `content` moves with a content update. The version name, the commit and
the whole launcher line belong to the installed app build, so after a content
update that brings a newer launcher, the second line still names the old one
until the next app build.

Inside the template and in a hand-vendored copy there is no synced commit, so
the second line is just `launcher 2.7.1`. It is the first thing worth asking for
in a launcher bug report.

The sync writes the hash into `addons/launcher/launcher_version.gd` from its
record, `addons/launcher/.launcher-sync.json`, on every run. A synced game
whose app build shows no hash on the second line was built without that
stamp. Once the game's `ci/` includes this, the next sync run opens a pull
request that adds it, even when there is nothing new to sync.

`VERSION` is hand-maintained, and `ci/check_launcher_version.sh` fails a pull
request that changes `addons/launcher/` without moving it — label the pull
request `no-launcher-bump` for a change that genuinely does not warrant one.

### Look

`theme_override` replaces the bundled theme wholesale. Leave it empty to keep
the default dark-green one. One thing it cannot style is a panel around the
update dialog's text: the dialog's own `PanelContainer` panel is its frame, so
the text area ignores the theme's `ScrollContainer` panel.

Your theme sets fonts, buttons and panels, but not the colour or size of the
title, the tagline, the status line, the version stamp or the dialog's text:
the launcher's scene sets those itself. Pick a background they read against,
or raise `background_dim`.

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
- **It runs again each time your game comes back to the launcher.**
  Connections to the launcher's own signals go away with it. For an
  autoload's signal, connect a method of your hooks script, not a lambda. The
  method's connection is dropped when the launcher closes. The lambda's stays
  connected, so one more piles up each time the player comes back.
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
- **It lives as long as the launcher.** The script is created each time the
  launcher opens and kept until it closes. If it `extends Node`, it is added as
  the launcher's child, so `_ready()`, `_process()` and input callbacks work,
  and whatever it adds is freed with the launcher. Its `_init()` must take no
  arguments, or the file is skipped with a warning.

### What your code can use

- **The launcher**, the `launcher` your hook receives: the signals
  `custom_button_pressed(label)`, `play_requested()` and `back_requested()`,
  and `register_translations(paths)`.
- **`UpdateService`**, an autoload. It ships in content packs, so it is always
  the current one: `state` and `state_changed`, `check_completed`,
  `check_for_updates()`, `apply_pending_update()`, `status_text()` and
  `history_text()`, for a game that drives updates from its own screens.
- **`BuildInfo`**, an autoload that stays at the installed app build's
  version: `version_name`, `binary_version`, `content_version`,
  `platform_key()`, `display_version()` and `config`. Test a newer member by
  name before using it, as above.

A change that would stop any of these working moves the launcher's major
version (`VERSION` in `addons/launcher/launcher_version.gd`).

### Language

The launcher's own screens translate through Godot's usual gettext support. It
ships a template of its strings at
[`addons/launcher/launcher.pot`](addons/launcher/launcher.pot), generated by
`ci/make_pot.py`.

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
   It reads the `.po`, `.mo` and imported `.translation` files directly inside
   each folder you pass, not those in subfolders.
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
starter workflows are **not** synced. When they change upstream — or when the
template adds one you do not have — the sync says so in the run summary of every
sync run, and in the pull request body when one is opened. You copy them across
by hand. The sync cannot tell an edit of your own from a change upstream. A
branch you added to `release.yml` therefore gets that file reported on every
run, and copying it across drops your branch, so put the edit back after
copying.

> A pull request opened with `GITHUB_TOKEN` does not trigger other workflows, so
> the sync job runs the import-and-boot check itself before opening the PR. To
> run your full CI on it as well, close the pull request and reopen it. A
> personal access token also works, but only by editing `sync-launcher.yml`,
> which the sync then reports as changed upstream on every run.

## Layout

| Path | |
|---|---|
| `addons/launcher/` | **The launcher.** Synced into games; never edit downstream |
| `addons/launcher/launcher.tscn` | The launcher scene, and every game's main scene; its path never changes |
| `addons/launcher/launcher_config.gd` | Every knob, documented inline |
| `addons/launcher/launcher_version.gd` | The launcher's own version; CI fails a launcher change that does not bump `VERSION`. In a game, that check turns itself off once `.launcher-sync.json` exists |
| `addons/launcher/launcher.pot` | The launcher's strings, to translate |
| `ci/` | Build and release scripts. Also synced |
| `template/` | The one starter file a game copies **once**: `export_presets.cfg` |
| `.github/workflows/` | The template's own CI — and exactly what a game gets |
| `docs/GETTING-STARTED.md` | **Start here.** Zero to a self-updating release |
| `docs/TROUBLESHOOTING.md` | Symptoms, and what each one means |
| `docs/UPDATES.md` | How updating actually works, in depth |
| `version.json` | Game name, `version_name` and `binary_version` |
| `launcher_config.tres` | The demo's config; your game's after setup |
| `build_version.gd` | The build stamp, at the path the launcher reads it from. CI overwrites it before each export; never edit it |
| `project.godot`, `export_presets.cfg`, `icon.svg` | The demo project; `ci/new_game.sh` swaps in `template/`'s presets |
| `.gitattributes` | Keeps text files on LF line endings, so scripts written on Windows still run in CI |
| `.claude/`, `CLAUDE.md` | Tooling for working on this repository; a game can delete them |
| `LICENSE` | MIT. Copies also live in `addons/launcher/` and `ci/`, so the terms travel with the synced code |

## Does this need anything from me?

No. The template is public, and a game syncs from it with an anonymous clone —
no token, no account, no permission. Fork it if you would rather not depend on
this repo moving under you, and point `LAUNCHER_TEMPLATE_REPO` in the sync
workflow at your fork. In the fork itself, change the `if:` line beside it too,
or the fork opens sync pull requests against itself.

Nothing is shared between games that use it: each one has its own repository,
its own releases, its own Android package id and its own signing key.

## Documentation

| | |
|---|---|
| [Getting started](docs/GETTING-STARTED.md) | The walkthrough, with what you should see at each step |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | "App not installed", no pull request, updates not detected… |
| [How updates work](docs/UPDATES.md) | The two version numbers, the manifest, signing, per-platform behaviour, trying a change on a device before it ships, publishing from a private repository, running the workflows on your own machine |

## Requirements

Godot **4.7**, no C#, no addons. Android builds need the SDK in CI (the supplied
workflow sets it up) and a signing keystore for real self-update. Running
`ci/new_game.sh` needs bash, git and Python 3 (on Windows, Git Bash and Python).

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
