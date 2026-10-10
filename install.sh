#!/bin/bash
# Build (Release) + install to /Applications + register + set default md handler + reset Quick Look.
set -e
cd "$(dirname "$0")"

DD="${LEAFLIGHT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/leaflight-build}"
./build.sh Release
APP="$DD/Build/Products/Release/Leaflight.app"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "Install -> /Applications/Leaflight.app"
rm -rf /Applications/Leaflight.app
cp -R "$APP" /Applications/Leaflight.app

# avoid duplicate bundle-id copies confusing Launch Services
"$LSREG" -u "$APP" 2>/dev/null || true
"$LSREG" -f /Applications/Leaflight.app

# set Leaflight as default app for Markdown
swift - <<'SWIFT' 2>/dev/null || true
import AppKit
import UniformTypeIdentifiers
let sem = DispatchSemaphore(value: 0)
if let md = UTType("net.daringfireball.markdown") {
    Task {
        try? await NSWorkspace.shared.setDefaultApplication(
            at: URL(fileURLWithPath: "/Applications/Leaflight.app"), toOpen: md)
        sem.signal()
    }
    sem.wait()
}
SWIFT

qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
echo "Done. Default md app + Quick Look ready."
