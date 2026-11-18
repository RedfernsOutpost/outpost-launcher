#!/bin/zsh
# One-time setup for Outpost Launcher. Safe to run again.
#   - checks Xcode (the launcher and nxnative both compile with it) and nxnative
#   - installs vgmstream and ffmpeg with Homebrew (audio/video decoding for make_theme.py)
#   - makes .venv with UnityPy and Pillow (art from Unity games, logo cut-outs)
set -e
KIT="${0:A:h}"
NX="${NXNATIVE:-$HOME/nxnative}"
ok() { print -P "%F{green}✓%f $1"; }
bad() { print -P "%F{red}✗%f $1"; FAIL=1; }
FAIL=0
if xcrun --find swiftc >/dev/null 2>&1 && [[ -d "$(xcode-select -p 2>/dev/null)" ]]; then ok "Xcode: $(xcode-select -p)"
else bad "Xcode not found or not selected. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"; fi
if [[ -f "$NX/dm/tools/romfs.py" ]]; then ok "nxnative: $NX"
else bad "nxnative not found at $NX. Set it up first (https://github.com/seedds/nxnative), or set NXNATIVE=/path/to/it"; fi
if ! command -v brew >/dev/null && [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
if command -v brew >/dev/null; then
  for f in vgmstream ffmpeg; do
    if brew list --formula "$f" >/dev/null 2>&1; then ok "$f"; else echo "installing $f…"; brew install "$f" && ok "$f"; fi
  done
else bad "Homebrew not found: install it from https://brew.sh, then run this again"; fi
PY=""
for p in "$NX/.venv/bin/python" /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3; do
  if [[ -x "$p" ]] && "$p" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then PY="$p"; break; fi
done
if [[ -n "$PY" ]]; then
  [[ -x "$KIT/.venv/bin/python" ]] || "$PY" -m venv "$KIT/.venv"
  "$KIT/.venv/bin/python" -m pip install -q --upgrade pip
  "$KIT/.venv/bin/python" -m pip install -q "UnityPy>=1.25,<2" "Pillow>=11"
  ok "Python tools in $KIT/.venv"
else bad "Python 3.10 or newer not found (brew install python)"; fi
(( FAIL )) && { echo; echo "Fix the ✗ lines above and run setup.sh again."; exit 1; }
echo; echo "Ready. Next: zsh make_launcher.sh <game> --from <your built game app>"
