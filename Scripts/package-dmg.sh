#!/bin/zsh
# Packages build/MoreBar.app into a signed DMG ready for notarization.
#
#   Scripts/package-dmg.sh              # uses VERSION=0.1.0
#   VERSION=0.2.0 Scripts/package-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: NexaTech Consulting (PTY) LTD (BG4SARWKL9)}"
APP=build/MoreBar.app
DMG=dist/MoreBar-$VERSION.dmg
STAGING=dist/dmg-staging

[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/build-app.sh first" >&2; exit 1; }

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" dist
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "MoreBar" -srcfolder "$STAGING" -ov -format UDZO "$DMG" -quiet
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --strict "$DMG"
rm -rf "$STAGING"

shasum -a 256 "$DMG"
echo "OK: $DMG"
