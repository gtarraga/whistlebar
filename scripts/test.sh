#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAGS=(--disable-xctest)
if [ "$(uname -s)" = Darwin ]; then
    # CLT 27 includes Swift Testing, but Swift Build does not discover its macro
    # plugin automatically. Full Xcode and older toolchains discover it normally.
    PLUGIN="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [ -f "$PLUGIN" ]; then
        FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "$PLUGIN")
    fi
fi
swift test --package-path "$ROOT" "${FLAGS[@]}" "$@"
