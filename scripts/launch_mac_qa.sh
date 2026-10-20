#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "Usage: scripts/launch_mac_qa.sh <RiverDiaryMacQA.app>"
  exit 64
fi

app_path="${1:A}"
info_plist="$app_path/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
  print -u2 "QA app bundle is missing Contents/Info.plist: $app_path"
  exit 66
fi

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
if [[ "$bundle_id" != "studio.riverdiary.mac.qa" ]]; then
  print -u2 "Refusing to launch non-QA bundle: $bundle_id"
  exit 65
fi

executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")
qa_home="${RIVER_DIARY_MAC_QA_HOME:-${TMPDIR%/}/RiverDiaryMacQAHome-$(id -u)}"
mkdir -p "$qa_home"
qa_home="$(cd "$qa_home" && pwd -P)"
real_home="$(cd "$HOME" && pwd -P)"
temporary_root="$(cd "${TMPDIR%/}" && pwd -P)"
shared_temporary_root="$(cd /tmp && pwd -P)"

case "$qa_home/" in
  "$real_home/"*)
    print -u2 "QA home must not be inside the real user home."
    exit 65
    ;;
esac

case "$qa_home/" in
  "$temporary_root/"*|"$shared_temporary_root/"*) ;;
  *)
    print -u2 "QA home must be inside TMPDIR or /tmp."
    exit 65
    ;;
esac

# Keep collection, outbound analysis, and LAN transport disabled for every QA launch.
/usr/bin/defaults write "$bundle_id" activity.enabled -bool false
/usr/bin/defaults write "$bundle_id" activity.capturesTitles -bool false
/usr/bin/defaults write "$bundle_id" ingestion.enabled -bool false
/usr/bin/defaults write "$bundle_id" ingestion.exportExplicitlyEnabled -bool false
/usr/bin/defaults write "$bundle_id" ai.footprint.allowRemoteAnalysis -bool false
/usr/bin/defaults write "$bundle_id" river.lanReplication.enabled -bool false

exec /usr/bin/env \
  CFFIXED_USER_HOME="$qa_home" \
  RIVER_DIARY_MAC_QA_HOME="$qa_home" \
  "$app_path/Contents/MacOS/$executable"
