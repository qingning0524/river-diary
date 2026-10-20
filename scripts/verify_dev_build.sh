#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MAC_ROOT="$PROJECT_ROOT/macos/RiverDiaryMac"
APP="$PROJECT_ROOT/dist/River Diary.app"
XCODE_BETA_APP="${XCODE_BETA_APP:-$HOME/Downloads/Xcode-beta.app}"
export XCODE_BETA_APP

if [[ -z "${DEVELOPER_DIR:-}" && -d "$XCODE_BETA_APP/Contents/Developer" ]]; then
  export DEVELOPER_DIR="$XCODE_BETA_APP/Contents/Developer"
fi
source "$PROJECT_ROOT/scripts/select_xcode.sh"

cd "$MAC_ROOT"
./make_app.sh >/tmp/river-diary-build.log

cd "$PROJECT_ROOT"
git diff --check

if rg -n -P '(?<!\\)\((latest|place|activity|corrected|selectedTable)\)' macos/RiverDiaryMac/Sources/RiverDiaryMac/Views -g '*.swift'; then
  echo "UI interpolation scan failed" >&2
  exit 1
fi

test -x "$APP/Contents/MacOS/RiverDiary"
test -d "$APP/Contents/Frameworks/SQLCipher.framework"
otool -L "$APP/Contents/MacOS/RiverDiary" | rg -q '@rpath/SQLCipher.framework'
otool -l "$APP/Contents/MacOS/RiverDiary" | rg -q '@executable_path/../Frameworks'
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/libexec/PlistBuddy -c 'Print:NSLocationUsageDescription' "$APP/Contents/Info.plist" >/dev/null

if [[ -n "${DEVELOPER_DIR:-}" && "$DEVELOPER_DIR" != "/Library/Developer/CommandLineTools" ]]; then
  "$PROJECT_ROOT/scripts/test_macos_isolated.sh" --disable-sandbox > /tmp/river-diary-tests.log 2>&1
  rg 'Executed [0-9]+ tests, with 0 failures' /tmp/river-diary-tests.log | tail -1
else
  echo "XCODE_TESTS_SKIPPED: Xcode Beta not found at $XCODE_BETA_APP"
fi

echo "DEV_BUILD_OK"
echo "APP=$APP"
echo "BUILD_LOG=/tmp/river-diary-build.log"
