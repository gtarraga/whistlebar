#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_REV=d6c7d6a2e9655505e0f8e23339356dd1705900eb
MODEL_REV=741118687e1f008f06d1351a402a731274789790
mkdir -p "$ROOT/Vendor"

fetch() {
    local name="$1" url="$2" expected="$3"
    local file="$ROOT/Vendor/$name"
    if [ -f "$file" ] && echo "$expected  $file" | shasum -a 256 --check --status; then
        return
    fi
    echo "Downloading $name…"
    curl --fail --location --retry 3 "$url" -o "$file.download"
    if ! echo "$expected  $file.download" | shasum -a 256 --check --status; then
        rm -f "$file.download"
        echo "Checksum failed for $name" >&2
        exit 1
    fi
    mv "$file.download" "$file"
}

fetch libneedle.a "https://huggingface.co/Cactus-Compute/needle3/resolve/$ENGINE_REV/macos-arm64/libneedle.a" \
    7d1368a4a42a745aba055f310913c3ed6d929dee98a89dcb955b9032b2335700
fetch needle.h "https://huggingface.co/Cactus-Compute/needle3/resolve/$ENGINE_REV/macos-arm64/needle.h" \
    a27dac4b3239eead91d124b7f7dbce5495c13019903fd817b68c16d39b055a99
fetch whistle.cact "https://huggingface.co/Cactus-Compute/whistle/resolve/$MODEL_REV/whistle.cact" \
    b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb
fetch LICENSE-Needle-Whistle.txt "https://huggingface.co/Cactus-Compute/needle3/resolve/$ENGINE_REV/LICENSE" \
    cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
