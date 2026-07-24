#!/bin/zsh
# Builds MoreBar.app from the SwiftPM binary and signs it.
#
#   Scripts/build-app.sh                   # Developer ID signing (stable TCC grants across builds)
#   SIGN_IDENTITY=- Scripts/build-app.sh   # ad-hoc signing
#   VERSION=0.2.0 Scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: NexaTech Consulting (PTY) LTD (BG4SARWKL9)}"
APP=build/MoreBar.app

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Support/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/arm64-apple-macosx/release/MoreBar "$APP/Contents/MacOS/MoreBar"

codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "OK: $APP (v$VERSION, build $BUILD)"
