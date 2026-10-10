#!/bin/bash
# Build a Developer ID-signed, Apple-notarized, stapled, Universal MapleDown.app and zip it.
#
# Prerequisites (one-time):
#   - A "Developer ID Application" certificate in your keychain
#     (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials mapledown-notary \
#         --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific-password>
#
# Usage:
#   MAPLEDOWN_TEAM_ID=XXXXXXXXXX ./release.sh [version]
set -e
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
TEAM_ID="${MAPLEDOWN_TEAM_ID:?set MAPLEDOWN_TEAM_ID to your 10-char Apple Developer Team ID}"
SIGN_ID="${MAPLEDOWN_SIGN_ID:-Developer ID Application}"
NOTARY_PROFILE="${MAPLEDOWN_NOTARY_PROFILE:-mapledown-notary}"
DD="$HOME/Library/Developer/Xcode/DerivedData/mapledown-build"
APP="$DD/Build/Products/Release/MapleDown.app"
ZIP="/tmp/MapleDown-v$VERSION-macos.zip"

command -v xcodegen >/dev/null && xcodegen generate

echo "==> Building Universal Release, signed with Developer ID + hardened runtime"
rm -rf "$DD/Build/Products/Release"
xcodebuild -project MapleDown.xcodeproj -scheme MapleDown -configuration Release -derivedDataPath "$DD" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

echo "==> Notarizing (waits for Apple)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling + repackaging"
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"

spctl -a -vvv -t exec "$APP" || true

# The notarized .app now lives in $ZIP. Leaving the DerivedData build copy on
# disk lets Launch Services register it; once the same app is also installed to
# /Applications, two bundles share io.github.zzzyx28.mapledown(.QuickLookExtension) and pkd
# rejects one ("another plugin has precedent") — silently killing Quick Look.
# Drop the build copy so only the installed copy is ever registered.
echo "==> Cleanup: unregister + remove DerivedData build copy (prevents duplicate bundle-id that breaks Quick Look)"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREG" -u "$APP" 2>/dev/null || true
rm -rf "$DD/Build/Products/Release"

echo "==> Done: $ZIP"
echo "    Publish: gh release upload v$VERSION \"$ZIP\" --clobber"
