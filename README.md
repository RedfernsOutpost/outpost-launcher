# Outpost Launcher

Themed, console-style launchers for games built with [nxnative](https://github.com/seedds/nxnative) on Apple silicon Macs.

Each launcher is a small Mac app with the game's own logo, backdrops, menu music and menu sounds. It has:

- **Play**, **Settings**, **Content** and **Tools** menus. Settings shows nxnative's options for that game (display, controls, performance, audio) with ‹ › arrows, plus music and sound volume.
- A song switcher and a volume button in the corner.
- Keyboard and game controller support.
- An **INSTALL** button. Pick your own `.nsp` / `.nup` and it does the rest:
  - It checks your Mac and your keys first.
  - It sets up whatever it can by itself (the Metal compiler, Homebrew tools, nxnative, Python). Those lines say **AUTO**.
  - For the few things it can't do alone (installing Xcode or Homebrew), click the line and it opens the App Store, a Terminal window or a password box for you. It checks again by itself when you come back.
  - It builds the game, puts it inside the launcher, then reads the game's logo, pictures, music and menu sounds into the launcher.

  After that, the launcher is the only app you see.

**This kit contains no game files, art, audio or keys.** You supply your own legally dumped games and your own `prod.keys`. The art and audio are read from your copy of the game on your Mac, when you run the tools. So a launcher you make includes that game's art, and is for your own use only. Share the kit, not the launchers you make with it.

## Download

The easiest way: get a ready-made launcher from **[Releases](https://github.com/RedfernsOutpost/outpost-launcher/releases/latest)**.

1. Download the zip for your game and double-click it.
2. Open the app. macOS asks whether you want to open an app downloaded from the internet. Click **Open**. The launchers are signed and notarized by Apple, so there's no Open Anyway step.
3. The launcher offers to move itself out of Downloads. Click **Move to Applications**.
4. Choose **INSTALL**, pick your game file and keys, and follow the checks.

When the install finishes, press **DONE** to see the game's art and hear its music, then **PLAY**.

## Your own button layout

**Settings → Controls → Map buttons** sets a layout with the controller: pick a Switch button, press the button you want for it. It's shared by every Outpost Launcher and passed to the game as `DM_PAD_MAP`. Stock nxnative doesn't read that option yet (the launcher says so); a small patch for nxnative's controller code adds it. Until then, **Remap buttons** opens macOS's own controller settings.

## While you play

The launcher closes while the game runs (no window, no Dock icon) and comes back when the game ends, with your play time and a notice if the game crashed. Set **Tools → When the game closes** to *Close launcher* to skip that.

**In-game menu:** hold Home (or Minus and Plus together) for 2 seconds, or press Esc, for Resume, Restart game, Full screen, Change settings and Quit game. Change settings closes the game and opens the launcher. The launcher turns it on with `DM_GAME_MENU`; stock nxnative doesn't have it yet (the launcher says so), it takes a small patch to nxnative's window code. Save states aren't possible: nxnative runs the game as native code across many threads and the GPU, with nothing to snapshot.

## Games with recipes

| recipe | game | title ID |
|---|---|---|
| `suikoden` | Suikoden I & II HD Remaster | 01004BD017080000 |
| `shiningpearl` | Pokémon Shining Pearl (comes with a 60 fps profile) | 010018E011D92000 |
| `pokopia` | Pokémon Pokopia | 0400A3A01EE4C000 |
| `fireemblem` | Fire Emblem: Fortune's Weave | 04007EF01F8AE000 |
| `oot` | The Legend of Zelda: Ocarina of Time (Nintendo Switch Online) | 0400486024DEC000 |
| `firered` | Pokémon FireRed Version (Nintendo Switch Online) | 0100554023408000 |

A recipe is a `theme.json` (colours, fonts and layout matched to the game's own menus) plus the steps in `make_theme.py` that find the right art and audio in that game's files. Recipes were made against specific game versions. A different version might store things elsewhere; if so, `make_theme.py` will say which file it couldn't find.

## What you need

- A Mac with Apple silicon, running macOS 14 or newer.
- **Xcode**, from the App Store. Open it once so it installs its components, then run:
  - `sudo xcode-select -s /Applications/Xcode.app`
  - `xcodebuild -downloadComponent MetalToolchain`
- **nxnative**, cloned to `~/nxnative` and set up as its own README says (its Python venv in `~/nxnative/.venv`). If you keep it somewhere else, set `NXNATIVE=/path/to/nxnative`; the launcher's INSTALL button only looks in `~/nxnative`.
- [Homebrew](https://brew.sh). The launcher offers to install it if it's missing.
- Your own game dump and `prod.keys`. INSTALL looks for keys in `~/Documents/Games/Switch`, `~/.switch`, `~/Documents`, `~/Downloads` and `~/Desktop`, and tries the newest first. You can also pick the file yourself.

If you use a downloaded launcher, that's all: it sets up the rest itself.

To make launchers from the source instead, run this once:

```bash
zsh setup.sh
```

It checks the items above, installs `vgmstream` and `ffmpeg` with Homebrew, and makes `.venv` with UnityPy and Pillow.

## Making a launcher

**Option A: launcher first, then the game.** This is how the downloadable launchers work.

1. Make a plain launcher. It has the game's colours and title, but no art yet.

   ```bash
   zsh make_launcher.sh shiningpearl --out ~/Games/"Pokémon Shining Pearl.app"
   ```

2. Open it and choose **INSTALL**. Pick your `.nsp` / `.nup`; the update and DLC files next to it are picked up too. Pick your keys if it asks. It runs its checks, then builds the game into the launcher. This takes a while.
3. The launcher reads the art, music and sounds from the game by itself when the install finishes. (To redo it later: **Tools → Get art and music from the game**.)

**Option B: you already built the game with nxnative.**

```bash
zsh make_launcher.sh fireemblem --from ~/Games/"Fire Emblem Fortune's Weave.app"
```

This puts the launcher next to the game app. The launcher finds the game there. Choosing INSTALL is never needed.

**Ocarina of Time** needs one extra thing for its logo: a cover picture. The 1200×675 `imgs/covers/cover.jpg` that NSO dump tools save next to the game works. INSTALL picks it up from there by itself; with `make_launcher.sh`, pass it with `--cover`. Without one, the title is shown as text instead.

**FireRed** has no music files to take: GBA music is sequenced. Add your own `.m4a` files to the theme folder and list them under `"playlist"` in its `theme.json`, then run `make_launcher.sh` again.

### The first launch is slow

After the launcher is built or changed, macOS checks the whole app the first time it opens. A launcher with a large game inside can take a minute or two. After that it opens in a few seconds.

## Files

```
.github/workflows/    builds the downloadable launchers for each release
setup.sh              one-time setup (for making launchers from source)
make_launcher.sh      recipe → theme → launcher app, in one go
make_theme.py         reads a built game's files and writes a theme folder (art, music, sounds, theme.json)
launcher/
  Launcher.swift      the launcher itself (SwiftUI)
  Controllers.swift   controller list, button tester, pairing help and controller options
  build-launcher.sh   compiles it and wraps a theme folder into an .app
recipes/<game>/       theme.json (+ an nxnative profile where one helps)
tools/
  unity_art.py        exports textures from Unity Addressables games
  kt_rdb.py           reads Koei Tecmo "RDB" archives (.fdata)
  wwise_event_media.py  finds which Wwise .wem files a sound event plays
themes/               output of make_theme.py (holds game art; never share it)
```

### theme.json

| key | what it does |
|---|---|
| `name`, `presents`, `platform` | Title text. `presents` is the small line above the logo. |
| `gameApp` | The game app's file name, used when the game sits next to the launcher instead of inside it. |
| `titleID` | The game's title ID; INSTALL uses it to put the recipe's profile where nxnative looks for it. |
| `profile` | A folder in the theme with an nxnative `game.tsv`. INSTALL uses it as the game's profile. |
| `logo`, `logoWidth` | Logo image and its width in points. |
| `backgrounds`, `slideSeconds` | Backdrop slideshow. |
| `skyTop`, `skyBottom`, `layers` | Instead of backdrops: a gradient sky with drifting image layers. |
| `music` or `playlist` | One looping track, or a list of `{file, title, loopStart}` for the song switcher. |
| `sounds` | `move`, `select`, `back`, `start` menu sounds. |
| `accent`, `accent2`, `glow`, `accentText`, `text`, `dim`, `panel`, `border`, `shade`, `shadeStrength` | Colours, as `#RRGGBB`. |
| `menuFont`, `labelFont`, `bodyFont`, `thinFont` | Font names installed on macOS. |
| `content` | Extra `{label, value}` rows for the Content page. |

### Adding a game

1. Copy a recipe folder and edit its `theme.json`.
2. Add a function to `make_theme.py` that writes the files it names, and register it in `RECIPES`.
3. Read the game's files without unpacking them, through nxnative's `dm/tools/romfs.py`:
   - `Game.read(path)` returns a file's bytes.
   - `Game.find(name)` searches for a file by name.
4. `vgmstream-cli` decodes most console audio, and `ffmpeg` grabs frames from movies.

## Self-test switches

These environment variables are for testing, not everyday use:

- `LAUNCHER_SNAPSHOT=/path.png` draws the launcher's own window into a picture after `LAUNCHER_SNAPSHOT_DELAY` seconds (default 2). It doesn't capture the screen.
- `LAUNCHER_PANEL=SETTINGS|CONTENT|TOOLS|INSTALL` opens that panel at start.
- `LAUNCHER_TAB=AUDIO` opens that settings tab.
- `LAUNCHER_MUTE=1` turns off music and sounds.
- `LAUNCHER_FORCE_MOVE=1` shows the move-to-Applications panel; `LAUNCHER_NO_AUTOART=1` skips the automatic art step.

## Making a release

Push a version tag and GitHub builds the six launchers and attaches them to a release:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

## Where things go

- `~/nxnative`: nxnative, downloaded by INSTALL if it isn't there yet.
- `~/Library/Application Support/nxnative-launcher/`: the launcher's own Python setup.
- `~/Library/Logs/nxnative-launcher/art.log`: what the art step did.
- `<launcher folder>/<game> (build files)`: nxnative's work folder during an install. It's removed by itself after a successful install, and kept after a failed one so you can look at its logs.

## Credits

- [nxnative](https://github.com/seedds/nxnative) does all the real work of running the games.
- [vgmstream](https://github.com/vgmstream/vgmstream), [FFmpeg](https://ffmpeg.org), [UnityPy](https://github.com/K0lb3/UnityPy) and [Pillow](https://python-pillow.org) handle the audio, video and images.

This kit is an unofficial fan project and isn't affiliated with Nintendo, The Pokémon Company, Game Freak, ILCA, Koei Tecmo, Intelligent Systems, Konami or any game's publisher. Game names are used only to say which game a recipe is for.

The kit's code is under the MIT license (see `LICENSE`).
