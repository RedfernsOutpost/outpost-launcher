#!/bin/zsh
# Build, sign, notarize and publish the six ready-to-run launchers (runs on the maintainer's Mac).
#
#   zsh release.sh v1.1.0            # build + sign + notarize + upload to that GitHub release
#   zsh release.sh v1.1.0 --local    # build + sign + notarize only (zips in dist/)
#
# One-time setup on this Mac:
#   1. A "Developer ID Application" certificate (developer.apple.com → Certificates → +, or Xcode → Settings → Accounts → Manage Certificates → +).
#   2. Notary login saved in the Keychain:  xcrun notarytool store-credentials nxlauncher
#      (asks for your Apple ID, Team ID and an app-specific password from account.apple.com).
# Nothing secret is stored in this repo: the certificate and the login stay in your Keychain.
set -e
KIT="${0:A:h}"; cd "$KIT"
TAG="${1:?usage: zsh release.sh vX.Y.Z [--local]}"; LOCAL="${2:-}"
PROFILE="${NOTARY_PROFILE:-nxlauncher}"
ID=$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/')
[[ -n "$ID" ]] || { echo "No Developer ID Application certificate in the Keychain (see the top of this file)."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "No notary login saved as '$PROFILE' (see the top of this file)."; exit 1; }
echo "signing with your Developer ID certificate"

rm -rf dist; mkdir -p dist
for g in suikoden shiningpearl pokopia fireemblem oot firered; do
  name=$(plutil -extract name raw -o - recipes/$g/theme.json)
  app="dist/${name//: / - }.app"
  slug=$(print -r -- "$name" | iconv -f UTF-8 -t ASCII//TRANSLIT | tr -d "'\"^~" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//')
  zip="dist/$slug-Launcher.zip"
  echo "== $name"
  zsh make_launcher.sh $g --out "$app" >/dev/null
  codesign --force --options runtime --timestamp --sign "$ID" "$app"
  codesign --verify --strict "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait | grep -E 'status:|id:' | tail -2
  xcrun stapler staple -q "$app"
  spctl -a -t exec "$app" && echo "   Gatekeeper: accepted"
  rm -f "$zip"; ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"   # zip again with the ticket stapled
  rm -rf "$app"
done
ls -l dist
[[ "$LOCAL" == "--local" ]] && exit 0

if gh release view "$TAG" >/dev/null 2>&1; then gh release upload "$TAG" dist/*.zip --clobber
else
  git tag "$TAG" 2>/dev/null && git push -q origin "$TAG"
  gh release create "$TAG" dist/*.zip --title "Outpost Launcher $TAG" --notes-file .github/release-notes.md
fi
echo "published: $(gh release view "$TAG" --json url --jq .url)"
