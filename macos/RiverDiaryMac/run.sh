#!/usr/bin/env zsh
set -euo pipefail

cd "$(dirname "$0")"
source "../../scripts/select_xcode.sh"

RESOURCE="Sources/RiverDiaryMac/Resources/data.json"
if [[ ! -f "$RESOURCE" && -f "../../data/data.json" ]]; then
  mkdir -p "$(dirname "$RESOURCE")"
  cp "../../data/data.json" "$RESOURCE"
fi

export SWIFTPM_CACHE_PATH=".build/spm-cache"
export CLANG_MODULE_CACHE_PATH=".build/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH=".build/swift-module-cache"

"$RIVER_SWIFT_EXECUTABLE" build --disable-sandbox

# The executable links SQLCipher as @rpath/SQLCipher.framework, and its only
# build-directory rpath is <Products>/Frameworks. SwiftPM drops the framework in
# <Products>/Debug instead, so without this link the app aborts on launch with
# "Library not loaded: @rpath/SQLCipher.framework".
FRAMEWORKS=".build/out/Products/Frameworks"
mkdir -p "$FRAMEWORKS"
ln -sfn "$PWD/.build/out/Products/Debug/SQLCipher.framework" "$FRAMEWORKS/SQLCipher.framework"

exec ".build/out/Products/Debug/RiverDiaryMac"
