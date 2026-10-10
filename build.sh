#!/bin/bash
# Build MapleDown to DerivedData OUTSIDE the source tree.
# In-tree build output gets crawled by Spotlight + Xcode/VSCode indexers ->
# concurrent swift-frontend/mdworker spikes -> system memory pressure on low-RAM Macs.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-Release}"
DD="${MAPLEDOWN_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/mapledown-build}"

command -v xcodegen >/dev/null && xcodegen generate

echo "Building $CONFIG -> $DD"
ARCH_ARGS=()
if [ -n "${MAPLEDOWN_ARCHS:-}" ]; then
  ARCH_ARGS=(ARCHS="$MAPLEDOWN_ARCHS" ONLY_ACTIVE_ARCH=NO)
fi
xcodebuild -project MapleDown.xcodeproj -scheme MapleDown -configuration "$CONFIG" \
  -derivedDataPath "$DD" \
  "${ARCH_ARGS[@]}" \
  CODE_SIGN_IDENTITY="-" build

echo "Built: $DD/Build/Products/$CONFIG/MapleDown.app"
