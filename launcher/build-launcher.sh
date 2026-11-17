#!/bin/zsh
# Build a themed launcher app for one game.
#   zsh build-launcher.sh <theme folder> <output .app>
# The theme folder holds theme.json plus the files it names (logo, backgrounds, music, sounds);
# everything in it is copied into the app's Resources. The game app (theme.json "gameApp") is
# found relative to the output app's folder; its AppIcon.icns becomes the launcher's icon
# unless the theme folder has its own AppIcon.icns.
set -e
HERE="${0:A:h}"
THEME="${1:?theme folder}"; OUT="${2:?output .app}"
THEME="${THEME:A}"; OUT="${OUT:A}"
BIN="$HERE/.build/Launcher"
mkdir -p "$HERE/.build"
if [[ ! -x "$BIN" || "$HERE/Launcher.swift" -nt "$BIN" ]]; then
  echo "compiling launcher…"
  xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14 "$HERE/Launcher.swift" -o "$BIN"
fi
NAME=$(/usr/bin/plutil -extract name raw -o - "$THEME/theme.json")
GAMEAPP=$(/usr/bin/plutil -extract gameApp raw -o - "$THEME/theme.json")
SLUG=$(print -r -- "$NAME" | tr -cs 'A-Za-z0-9' '-' | tr 'A-Z' 'a-z' | sed 's/^-//; s/-$//')
XNAME=$(print -r -- "$NAME" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')   # XML-safe for Info.plist
[[ "$GAMEAPP" == /* ]] && GAMEPATH="$GAMEAPP" || GAMEPATH="${OUT:h}/$GAMEAPP"

rm -rf "$OUT.partial"; mkdir -p "$OUT.partial/Contents/MacOS" "$OUT.partial/Contents/Resources"
cp "$BIN" "$OUT.partial/Contents/MacOS/Launcher"
cp -R "$THEME/" "$OUT.partial/Contents/Resources/"
ICON=AppIcon
if [[ ! -f "$OUT.partial/Contents/Resources/AppIcon.icns" ]]; then
  if [[ -f "$GAMEPATH/Contents/Resources/AppIcon.icns" ]]; then cp "$GAMEPATH/Contents/Resources/AppIcon.icns" "$OUT.partial/Contents/Resources/"
  else echo "note: no AppIcon.icns found (game app at $GAMEPATH?)"; ICON=""; fi
fi
cat > "$OUT.partial/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Launcher</string>
  <key>CFBundleIdentifier</key><string>local.nxlauncher.$SLUG</string>
  <key>CFBundleName</key><string>$XNAME</string>
  <key>CFBundleDisplayName</key><string>$XNAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
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
