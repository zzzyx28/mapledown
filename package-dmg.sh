#!/bin/bash
# Build MapleDown and package a local-use drag-and-drop DMG.
set -euo pipefail
cd "$(dirname "$0")"

DD="${MAPLEDOWN_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/mapledown-build}"
APP="$DD/Build/Products/Release/MapleDown.app"
DIST="$PWD/dist"

./build.sh Release

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/MapleDown" | tr ' ' '-')
DMG="$DIST/MapleDown-$VERSION-macOS-$ARCHS.dmg"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/mapledown-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$DIST"
/usr/bin/ditto "$APP" "$STAGE/MapleDown.app"
/bin/ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -volname "MapleDown $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Created: $DMG"
