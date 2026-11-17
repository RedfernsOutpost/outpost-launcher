# nxnative launcher kit

Themed, console-style launchers for games built with [nxnative](https://github.com/seedds/nxnative) on Apple silicon Macs.

Each launcher is a small Mac app with the game's own logo, backdrops, menu music and menu sounds. It has:

- **Play**, **Settings**, **Content** and **Tools** menus. Settings shows nxnative's options for that game (display, controls, performance, audio) with ‹ › arrows, plus music and sound volume.
- A song switcher and a volume button in the corner.
- Keyboard and game controller support.
- An **INSTALL** button. The first time you open a launcher, INSTALL builds the game from your own `.nsp` / `.nup` and puts it inside the launcher. It checks Xcode, Metal, nxnative, free space and your keys first. If something is missing, it tells you exactly what to do; click a red line to copy its fix. After that, the launcher is the only app you see.

**This kit contains no game files, art, audio or keys.** You supply your own legally dumped games and your own `prod.keys`. The art and audio are read from your copy of the game on your Mac, when you run the tools. So a launcher you make includes that game's art, and is for your own use only. Share the kit, not the launchers you make with it.

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
- [Homebrew](https://brew.sh).
- Your own game dump and `prod.keys`. INSTALL looks for keys in `~/Documents/Games/Switch`, `~/.switch`, `~/Documents`, `~/Downloads` and `~/Desktop`, and tries the newest first. You can also pick the file yourself.

Then run this once:

```bash
zsh setup.sh
```

It checks the items above, installs `vgmstream` and `ffmpeg` with Homebrew, and makes `.venv` with UnityPy and Pillow.

## Making a launcher

**Option A: launcher first, then the game.**

1. Make a plain launcher. It has the game's colours and title, but no art yet.

   ```bash
   zsh make_launcher.sh shiningpearl --out ~/Games/"Pokémon Shining Pearl.app"
   ```

2. Open it and choose **INSTALL**. Pick your `.nsp` / `.nup`; the update and DLC files next to it are picked up too. Pick your keys if it asks. It runs its checks, then builds the game into the launcher. This takes a while.
3. Add the art, music and sounds from the game you just installed. The launcher is rebuilt in place, and the game stays inside it.

   ```bash
   zsh make_launcher.sh shiningpearl --from ~/Games/"Pokémon Shining Pearl.app"
   ```

**Option B: you already built the game with nxnative.**

```bash
zsh make_launcher.sh fireemblem --from ~/Games/"Fire Emblem Fortune's Weave.app"
```

This puts the launcher next to the game app. The launcher finds the game there. Choosing INSTALL is never needed.

**Ocarina of Time** needs one extra thing for its logo: a cover picture. Pass it with `--cover`; the 1200×675 `imgs/covers/cover.jpg` that NSO dump tools save works. Without `--cover`, the title is shown as text instead.

**FireRed** has no music files to take: GBA music is sequenced. Add your own `.m4a` files to the theme folder and list them under `"playlist"` in its `theme.json`, then run `make_launcher.sh` again.

### The first launch is slow

After the launcher is built or changed, macOS checks the whole app the first time it opens. A launcher with a large game inside can take a minute or two. After that it opens in a few seconds.

## Files

```
setup.sh              one-time setup
make_launcher.sh      recipe → theme → launcher app, in one go
make_theme.py         reads a built game's files and writes a theme folder (art, music, sounds, theme.json)
launcher/
  Launcher.swift      the launcher itself (SwiftUI, one file)
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

## Credits

- [nxnative](https://github.com/seedds/nxnative) does all the real work of running the games.
- [vgmstream](https://github.com/vgmstream/vgmstream), [FFmpeg](https://ffmpeg.org), [UnityPy](https://github.com/K0lb3/UnityPy) and [Pillow](https://python-pillow.org) handle the audio, video and images.

This kit is an unofficial fan project and isn't affiliated with Nintendo, The Pokémon Company, Game Freak, ILCA, Koei Tecmo, Intelligent Systems, Konami or any game's publisher. Game names are used only to say which game a recipe is for.

The kit's code is under the MIT license (see `LICENSE`).
