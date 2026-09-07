#!/usr/bin/env zsh
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${RIVER_BUILD_CONFIG:-release}"
RESOURCE="Sources/RiverDiaryMac/Resources/data.json"
if [[ -f "../../data/data.json" ]]; then
  mkdir -p "$(dirname "$RESOURCE")"
  cp "../../data/data.json" "$RESOURCE"
elif [[ ! -f "$RESOURCE" ]]; then
  echo "No project data.json found; using the existing bundled snapshot." >&2
fi

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -d "$SDK" ]]; then
  export SDKROOT="$SDK"
fi

export SWIFTPM_CACHE_PATH=".build/spm-cache"
export CLANG_MODULE_CACHE_PATH=".build/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH=".build/swift-module-cache"
BIN_DIR=".build/out/Products/$CONFIG"
rm -f "$BIN_DIR/RiverDiaryMac"

if ! swift build -c "$CONFIG" --disable-sandbox; then
  if [[ ! -x "$BIN_DIR/RiverDiaryMac" ]]; then
    exit 1
  fi
  echo "Build completed without debug-symbol bundle; packaging executable."
fi
BINARY="$BIN_DIR/RiverDiaryMac"
RESOURCE_BUNDLE="$BIN_DIR/RiverDiaryMac_RiverDiaryMac.bundle"
APP_DIR="../../dist/River Diary.app"

if [[ ! -x "$BINARY" ]]; then
  echo "Missing executable: $BINARY" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/RiverDiary"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
cp "Sources/RiverDiaryMac/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>River Diary</string>
  <key>CFBundleDisplayName</key><string>River Diary</string>
  <key>CFBundleExecutable</key><string>RiverDiary</string>
  <key>CFBundleIdentifier</key><string>studio.riverdiary.mac</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --deep --sign - "$APP_DIR"

echo "Created $APP_DIR"
