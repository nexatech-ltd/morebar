#!/bin/zsh
# Notarizes and staples the app and the DMG.
#
# One-time setup (creates the "morebar-notary" keychain profile; the
# app-specific password is generated at https://account.apple.com under
# Sign-In and Security > App-Specific Passwords):
#
#   xcrun notarytool store-credentials morebar-notary \
#     --apple-id cto@omniaid.io --team-id BG4SARWKL9
#
# Flow (belt and suspenders): notarize + staple the .app first, rebuild the
# DMG with the stapled app, then notarize + staple the DMG itself. Installs
# then verify offline both from the DMG and after copying to /Applications.
#
#   VERSION=0.1.0 Scripts/notarize.sh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
PROFILE="${PROFILE:-morebar-notary}"
APP=build/MoreBar.app
DMG=dist/MoreBar-$VERSION.dmg

[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/build-app.sh first" >&2; exit 1; }

echo "==> Notarizing the app"
ZIP=dist/MoreBar-$VERSION-notarize.zip
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> Rebuilding the DMG with the stapled app"
VERSION="$VERSION" Scripts/package-dmg.sh

echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "OK: $DMG is notarized and stapled"
