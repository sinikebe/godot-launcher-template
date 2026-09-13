# Getting started

From nothing to a game people can install, that updates itself, in about
fifteen minutes. No prior GitHub Actions knowledge needed.

**What you need:** [Godot 4.7](https://godotengine.org/download), a GitHub
account, and [`gh`](https://cli.github.com) or git on the command line.

---

## 1. Make your repository

Open [the template](https://github.com/sinikebe/godot-launcher-template) and
click **Use this template → Create a new repository**. Name it after your game.

Make it **public** unless you have a reason not to — the updater downloads from
your releases, and private releases need a token the app will not have.

Then clone it:

```bash
git clone https://github.com/you/your-game
cd your-game
```

## 2. Name your game

One command sets up everything:

```bash
bash ci/new_game.sh "Deep Cavern" com.yourname.deepcavern
```

- **"Deep Cavern"** — shown on the launcher. Release files derive from it
  (`deep-cavern.apk`, `DeepCavern.exe`), so pick it before your first release.
- **com.yourname.deepcavern** — your Android package id. It must be unique
  across every app on a phone. Two apps sharing one collide, and then neither
  can update the other. Use your own name or domain; never leave the example.

> **You should see** a list of changed files ending in `template/ moved into
> place and removed`.

Commit it:

```bash
git add -A
git commit -m "Set up Deep Cavern"
git push
```

## 3. Let the robot open pull requests

In your repository: **Settings → Actions → General → Workflow permissions** →
tick **Allow GitHub Actions to create and approve pull requests** → Save.

This is what lets the daily launcher sync open a PR for you later. Without it
the sync still runs, it just cannot open the PR.

## 4. Watch it build

Your push already started a build. Open the **Actions** tab.

> **You should see** a *Release* run go green in a few minutes, and a new
> release appear under **Releases** containing `deep-cavern.apk`,
> `DeepCavern.exe`, two `.pck` files, `manifest.json` and `SHA256SUMS`.

If it failed, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 5. Install it

Download the `.exe` and run it, or put the `.apk` on an Android phone.

> **You should see** your game's name, a Play button, and along the bottom
> `Up to date.` with a **Check for updates** button. Bottom right shows your
> version and which launcher build you are on.

Android will ask to allow installs from whichever app opened the APK. That is
normal for anything outside the Play Store.

## 6. Watch it update itself

This is the part worth seeing work.

```bash
# change something visible, e.g. the title in launcher_config.tres
git commit -am "Rename the title"
git push
```

Wait for the build, then open the copy you installed and press **Check for
updates**.

> **You should see** `Content update available`, then patch notes taken from
> your commit message, then a download and a **Restart** prompt. After the
> restart, your change is there — no reinstall.

That was a *content* update: a few tens of kilobytes. Read
[UPDATES.md](UPDATES.md#the-two-version-numbers) for when you need to bump
`binary_version` instead and ship a whole new APK.

---

## Android: set up signing before you share it

Skip this while you are the only one installing. Do it **before anyone else
does**, because changing the key later forces everyone to uninstall first.

Android refuses to update an app when the new file is signed with a different
key. Without your own keystore, CI signs with a throwaway debug key that only
survives in the build cache — so in-place updates eventually break.

Create a key (any machine with a JDK — Android Studio ships one):

```bash
keytool -genkeypair -v \
  -keystore release.keystore \
  -alias release \
  -keyalg RSA -keysize 4096 -validity 10950 \
  -dname "CN=Deep Cavern, O=YourName, C=FR"
```

Add it to your repository as three secrets:

```bash
gh secret set ANDROID_KEYSTORE_BASE64 < <(base64 -w0 release.keystore)
gh secret set ANDROID_KEYSTORE_PASSWORD   # the password you just chose
gh secret set ANDROID_KEY_ALIAS           # release
```

> **Back up `release.keystore` and its password somewhere safe**, outside the
> repository. Lose them and you can never update anyone's installed copy again.

The next build picks them up automatically.

---

## Where things live

| You edit | |
|---|---|
| `launcher_config.tres` | Title, background, button placement, buttons — [full list](../README.md#making-it-yours) |
| `version.json` | Game name and version numbers |
| `export_presets.cfg` | Android package id, icons, architectures |
| your own scenes | The actual game |

| Leave alone | |
|---|---|
| `addons/launcher/` | The launcher. Replaced wholesale on every sync |
| `ci/` | Build scripts. Also replaced |

Editing those two is the most common mistake: it works until the next sync
quietly reverts it. Everything you legitimately need is in the config.

## Adding your game to the Play button

In `launcher_config.tres`, set **`play_scene`** to your first scene. Until then
Play explains itself rather than failing silently.

For more control, connect the launcher's `play_requested` signal and do
whatever you like instead.

## Staying up to date

Once a day a workflow pulls launcher improvements from the template, checks your
project still loads, and **opens a pull request**. It never merges — reviewing
and merging is your call, because merging publishes a release to your players.

To check right now: **Actions → Sync launcher → Run workflow**.
