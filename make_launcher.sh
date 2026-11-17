#!/bin/zsh
# Make a themed launcher for one game.
#
#   zsh make_launcher.sh <game> [--from <game app or launcher>] [--cover <image>] [--out <Name.app>]
#
#   <game>   suikoden | shiningpearl | pokopia | fireemblem | oot | firered
#   --from   the app nxnative built for your copy of the game (or a launcher that already has it inside).
#            The logo, backdrops, music and menu sounds are taken from it. Without --from you get a
#            plain launcher (colours and title only) whose INSTALL button builds the game from your
#            own .nsp/.nup; run this again afterwards with --from <that launcher> to add the art.
#   --cover  Ocarina of Time only: a cover picture to cut the logo from.
#   --out    where to put the launcher (default: next to --from, or the current folder).
set -e
KIT="${0:A:h}"
GAME="${1:?usage: zsh make_launcher.sh <game> [--from app] [--cover image] [--out Name.app]}"; shift
FROM="" COVER="" OUT=""
while (( $# )); do
  case "$1" in
    --from) FROM="${2:?}"; shift 2 ;;
    --cover) COVER="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done
[[ -d "$KIT/recipes/$GAME" ]] || { echo "no recipe called $GAME (have: ${(j:, :)$(ls "$KIT/recipes")})"; exit 1; }
THEME="$KIT/themes/$GAME"
if [[ -n "$FROM" ]]; then
  [[ -x "$KIT/.venv/bin/python" ]] || { echo "run setup.sh first"; exit 1; }
  ARGS=("$GAME" "$FROM" --out "$THEME"); [[ -n "$COVER" ]] && ARGS+=(--cover "$COVER")
  "$KIT/.venv/bin/python" "$KIT/make_theme.py" "${ARGS[@]}"
else
  mkdir -p "$THEME"; cp "$KIT/recipes/$GAME/theme.json" "$THEME/theme.json"
  [[ -f "$KIT/recipes/$GAME/game.tsv" ]] && { mkdir -p "$THEME/profile"; cp "$KIT/recipes/$GAME/game.tsv" "$THEME/profile/game.tsv"; }
  echo "plain theme (no art yet): $THEME"
fi
NAME=$(/usr/bin/plutil -extract name raw -o - "$THEME/theme.json")
FILE="${NAME//: / - }"; FILE="${FILE//[:\/]/-}.app"
if [[ -z "$OUT" ]]; then
  if [[ -n "$FROM" && -d "${FROM:A}/Contents/Game" ]]; then OUT="${FROM:A}"          # a launcher: rebuild it in place
  elif [[ -n "$FROM" ]]; then OUT="${FROM:A:h}/$FILE"
  else OUT="$PWD/$FILE"; fi
fi
zsh "$KIT/launcher/build-launcher.sh" "$THEME" "$OUT"
