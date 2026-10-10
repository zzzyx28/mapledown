#!/bin/bash
# Build Leaflight to DerivedData OUTSIDE the source tree.
# In-tree build output gets crawled by Spotlight + Xcode/VSCode indexers ->
# concurrent swift-frontend/mdworker spikes -> system memory pressure on low-RAM Macs.
set -e
cd "$(dirname "$0")"

CONFIG="${1:-Release}"
DD="${LEAFLIGHT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/leaflight-build}"

command -v xcodegen >/dev/null && xcodegen generate

echo "Building $CONFIG -> $DD"
ARCH_ARGS=()
if [ -n "${LEAFLIGHT_ARCHS:-}" ]; then
  ARCH_ARGS=(ARCHS="$LEAFLIGHT_ARCHS" ONLY_ACTIVE_ARCH=NO)
fi
xcodebuild -project Leaflight.xcodeproj -scheme Leaflight -configuration "$CONFIG" \
  -derivedDataPath "$DD" \
  "${ARCH_ARGS[@]}" \
  CODE_SIGN_IDENTITY="-" build

echo "Built: $DD/Build/Products/$CONFIG/Leaflight.app"
