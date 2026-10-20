#!/usr/bin/env zsh
set -euo pipefail

cd "$(dirname "$0")"
source "../../scripts/select_xcode.sh"

CONFIG="${RIVER_BUILD_CONFIG:-release}"
VERSION="${RIVER_APP_VERSION:-1.0.0}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
APP_DIR="${RIVER_APP_OUTPUT_DIR:-../../dist/River Diary.app}"

BUILD_ROOT="$(mktemp -d "${TMPDIR%/}/riverdiary-release-build.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
export SWIFTPM_CACHE_PATH=".build/spm-cache"
export CLANG_MODULE_CACHE_PATH=".build/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH=".build/swift-module-cache"
BIN_DIR="$("$RIVER_SWIFT_EXECUTABLE" build --show-bin-path -c "$CONFIG" --scratch-path "$BUILD_ROOT")"
RESOURCE_BUNDLE="$BIN_DIR/RiverDiaryMac_RiverDiaryMac.bundle"
"$RIVER_SWIFT_EXECUTABLE" build -c "$CONFIG" --scratch-path "$BUILD_ROOT" --disable-sandbox
BINARY="$BIN_DIR/RiverDiaryMac"

if [[ ! -x "$BINARY" ]]; then
  echo "Missing executable: $BINARY" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

cp "$BINARY" "$APP_DIR/Contents/MacOS/RiverDiary"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
cp "Sources/RiverDiaryMac/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
if /usr/bin/find "$APP_DIR/Contents" -type f \
  \( -name data.json -o -name ios-user-data.json -o -name river-diary-user-data.json \) \
  -print -quit | /usr/bin/grep -q .; then
  echo "Refusing to package a personal diary snapshot or user-data export." >&2
  exit 67
fi
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
  <key>NSLocalNetworkUsageDescription</key><string>启用附近设备快速复制后，River Diary 会通过本地网络交换已加密的同步对象。</string>
  <key>NSBonjourServices</key>
  <array><string>_riverdiary-sync._tcp</string></array>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>studio.riverdiary.mac.backup</string>
      <key>UTTypeDescription</key><string>River Diary Encrypted Backup</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>riverbackup</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$APP_DIR" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
fi

python3 ../../scripts/write_build_provenance.py "$APP_DIR" "${APP_DIR}.provenance.json"

echo "Created $APP_DIR"
