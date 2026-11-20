#!/bin/zsh
# Build a themed launcher app for one game.
#   zsh build-launcher.sh <theme folder> <output .app> [recipe]
# The theme folder holds theme.json plus the files it names (logo, backgrounds, music, sounds);
# everything in it is copied into the app's Resources. The game app (theme.json "gameApp") is
# found relative to the output app's folder; its AppIcon.icns becomes the launcher's icon
# unless the theme folder has its own AppIcon.icns.
# With a recipe name, the art maker (make_theme.py, tools/, recipes/<recipe>) goes in too, so the
# launcher can read the game's art and music by itself once the game is installed.
set -e
HERE="${0:A:h}"
THEME="${1:?theme folder}"; OUT="${2:?output .app}"; RECIPE="${3:-}"
KIT="${HERE:h}"
THEME="${THEME:A}"; OUT="${OUT:A}"
BIN="$HERE/.build/Launcher"
mkdir -p "$HERE/.build"
SOURCES=("$HERE"/*.swift)
if [[ ! -x "$BIN" || -n "$(find "$HERE" -maxdepth 1 -name '*.swift' -newer "$BIN")" ]]; then
  echo "compiling launcher…"
  xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 "${SOURCES[@]}" -o "$BIN"
fi
NAME=$(/usr/bin/plutil -extract name raw -o - "$THEME/theme.json")
GAMEAPP=$(/usr/bin/plutil -extract gameApp raw -o - "$THEME/theme.json")
SLUG=$(print -r -- "$NAME" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | tr -d "'\"^~" | tr -cs 'A-Za-z0-9' '-' | tr 'A-Z' 'a-z' | sed 's/^-//; s/-$//')
XNAME=$(print -r -- "$NAME" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')   # XML-safe for Info.plist
[[ "$GAMEAPP" == /* ]] && GAMEPATH="$GAMEAPP" || GAMEPATH="${OUT:h}/$GAMEAPP"

rm -rf "$OUT.partial"; mkdir -p "$OUT.partial/Contents/MacOS" "$OUT.partial/Contents/Resources"
cp "$BIN" "$OUT.partial/Contents/MacOS/Launcher"
cp -R "$THEME/" "$OUT.partial/Contents/Resources/"
if [[ -n "$RECIPE" ]]; then
  K="$OUT.partial/Contents/Resources/kit"
  mkdir -p "$K/tools" "$K/recipes"
  cp "$KIT/make_theme.py" "$K/"; cp "$KIT"/tools/*.py "$K/tools/"; cp -R "$KIT/recipes/$RECIPE" "$K/recipes/"
  print -r -- "$RECIPE" > "$K/recipe"
fi
ICON=AppIcon   # always named, so the game's icon shows once the art step adds it
if [[ ! -f "$OUT.partial/Contents/Resources/AppIcon.icns" ]]; then
  INNER=("$OUT"/Contents/Game/*.app(N))
  for G in "$GAMEPATH" "${INNER[@]}"; do
    if [[ -f "$G/Contents/Resources/AppIcon.icns" ]]; then cp "$G/Contents/Resources/AppIcon.icns" "$OUT.partial/Contents/Resources/"; break; fi
  done
fi
cat > "$OUT.partial/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Launcher</string>
  <key>CFBundleIdentifier</key><string>io.github.redfernsoutpost.launcher.$SLUG</string>
  <key>CFBundleName</key><string>$XNAME</string>
  <key>CFBundleDisplayName</key><string>$XNAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>3.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>$ICON</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
plutil -lint -s "$OUT.partial/Contents/Info.plist" || { echo "bad Info.plist"; exit 1; }
codesign --force --sign - "$OUT.partial" >/dev/null 2>&1
# Keep a game app installed inside the launcher (Contents/Game) across rebuilds.
if [[ -d "$OUT/Contents/Game" ]]; then mv "$OUT/Contents/Game" "$OUT.partial/Contents/Game"; fi
rm -rf "$OUT"; mv "$OUT.partial" "$OUT"
echo "built: $OUT"
