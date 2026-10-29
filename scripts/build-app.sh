#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "Build on an Apple Silicon Mac with macOS 26+ and Xcode 26 Command Line Tools." >&2
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Install Xcode Command Line Tools first: xcode-select --install" >&2
    exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ] || \
   [ "$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)" -lt 26 ]; then
    echo "The pinned Needle runtime requires macOS 26+ and a macOS 26+ SDK." >&2
    exit 1
fi
bash "$ROOT/scripts/fetch-runtime.sh"
bash "$ROOT/scripts/test.sh" --arch arm64
swift build --package-path "$ROOT" --arch arm64 -c release --product WhistleBar
BIN="$(swift build --package-path "$ROOT" --arch arm64 -c release --show-bin-path)"
APP="$ROOT/dist/WhistleBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/WhistleBar" "$APP/Contents/MacOS/WhistleBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Vendor/whistle.cact" "$ROOT/Vendor/LICENSE-Needle-Whistle.txt" "$APP/Contents/Resources/"
swift "$ROOT/scripts/generate-icon.swift" "$APP/Contents/Resources/AppIcon.icns"
# Local ad-hoc signing; use SIGNING_IDENTITY for your own Developer ID certificate.
codesign --force --sign "${SIGNING_IDENTITY:--}" --identifier local.WhistleBar "$APP"
codesign --verify --strict "$APP"
ditto -c -k --keepParent "$APP" "$ROOT/dist/WhistleBar.zip"
echo "Built: $APP"
echo "Copy WhistleBar.app into /Applications before granting permissions."
echo "This is a locally signed build, not an Apple-notarized distribution."
