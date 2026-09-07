#!/usr/bin/env zsh
set -euo pipefail

cd "$(dirname "$0")"

RESOURCE="Sources/RiverDiaryMac/Resources/data.json"
if [[ ! -f "$RESOURCE" && -f "../../data/data.json" ]]; then
  mkdir -p "$(dirname "$RESOURCE")"
  cp "../../data/data.json" "$RESOURCE"
fi

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -d "$SDK" ]]; then
  export SDKROOT="$SDK"
fi

export SWIFTPM_CACHE_PATH=".build/spm-cache"
export CLANG_MODULE_CACHE_PATH=".build/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH=".build/swift-module-cache"

swift build --disable-sandbox
exec ".build/out/Products/Debug/RiverDiaryMac"
