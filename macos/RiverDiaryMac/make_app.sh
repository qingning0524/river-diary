#!/usr/bin/env zsh
set -euo pipefail

cd "$(dirname "$0")"
source "../../scripts/select_xcode.sh"

CONFIG="${RIVER_BUILD_CONFIG:-release}"
VERSION="${RIVER_APP_VERSION:-1.0.0}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
RESOURCE="Sources/RiverDiaryMac/Resources/data.json"
if [[ -f "../../data/data.json" ]]; then
  mkdir -p "$(dirname "$RESOURCE")"
  cp "../../data/data.json" "$RESOURCE"
elif [[ ! -f "$RESOURCE" ]]; then
  echo "No project data.json found; using the existing bundled snapshot." >&2
fi

export SWIFTPM_CACHE_PATH=".build/spm-cache"
export CLANG_MODULE_CACHE_PATH=".build/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH=".build/swift-module-cache"
BIN_DIR=".build/out/Products/$CONFIG"
rm -f "$BIN_DIR/RiverDiaryMac"

if ! "$RIVER_SWIFT_EXECUTABLE" build -c "$CONFIG" --disable-sandbox; then
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
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

cp "$BINARY" "$APP_DIR/Contents/MacOS/RiverDiary"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
cp "Sources/RiverDiaryMac/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
if [[ -d "$BIN_DIR/SQLCipher.framework" ]]; then
  cp -R "$BIN_DIR/SQLCipher.framework" "$APP_DIR/Contents/Frameworks/SQLCipher.framework"
else
  echo "Missing SQLCipher.framework: $BIN_DIR/SQLCipher.framework" >&2
  exit 1
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>River Diary</string>
  <key>CFBundleDisplayName</key><string>River Diary</string>
  <key>CFBundleExecutable</key><string>RiverDiary</string>
  <key>CFBundleIdentifier</key><string>studio.riverdiary.mac</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationUsageDescription</key><string>河流日记只在你主动连接地点来源后读取位置，用于生成可纠正的个人足迹。</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$APP_DIR" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
fi

echo "Created $APP_DIR"
