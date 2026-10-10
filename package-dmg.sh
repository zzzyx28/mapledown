#!/bin/bash
# Build Leaflight and package a local-use drag-and-drop DMG.
set -euo pipefail
cd "$(dirname "$0")"

DD="${LEAFLIGHT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/leaflight-build}"
APP="$DD/Build/Products/Release/Leaflight.app"
DIST="$PWD/dist"

./build.sh Release

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/Leaflight" | tr ' ' '-')
DMG="$DIST/Leaflight-$VERSION-macOS-$ARCHS.dmg"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/leaflight-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$DIST"
/usr/bin/ditto "$APP" "$STAGE/Leaflight.app"
/bin/ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -volname "Leaflight $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Created: $DMG"
