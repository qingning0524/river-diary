#!/usr/bin/env zsh
# 两进程/两用户目录/两套 Keychain 命名空间的可移植恢复演练。
# 同一台 Mac 上的“干净用户目录”演练；仍建议在第二台真实 Mac 上重复一次。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/select_xcode.sh >/dev/null
swift build --package-path macos/RiverDiaryMac -c debug >/dev/null

binary="$PWD/macos/RiverDiaryMac/.build/debug/RiverDiaryMac"
[[ -x "$binary" ]] || { print -u2 "missing debug binary"; exit 66; }
key="river-sync-v1:$(openssl rand -base64 32 | tr -d '\n')"
src="$(mktemp -d "${TMPDIR%/}/river-drill-src.XXXXXX")"
dst="$(mktemp -d "${TMPDIR%/}/river-drill-dst.XXXXXX")"
work="$(mktemp -d "${TMPDIR%/}/river-drill.XXXXXX")"
portable="$work/portable.riverportable"
cleanup() { rm -rf "$src" "$dst" "$work"; }
trap cleanup EXIT

export_out=$(CFFIXED_USER_HOME="$src" RIVER_DIARY_KEYCHAIN_NAMESPACE="drill-src-$$" \
  RIVER_PORTABLE_DRILL=export RIVER_PORTABLE_DRILL_PATH="$portable" \
  RIVER_PORTABLE_DRILL_KEY="$key" "$binary" 2>&1)
print -r -- "$export_out"
print -r -- "$export_out" | grep -q 'DRILL_EXPORT_OK'

import_out=$(CFFIXED_USER_HOME="$dst" RIVER_DIARY_KEYCHAIN_NAMESPACE="drill-dst-$$" \
  RIVER_PORTABLE_DRILL=import RIVER_PORTABLE_DRILL_PATH="$portable" \
  RIVER_PORTABLE_DRILL_KEY="$key" "$binary" 2>&1)
print -r -- "$import_out"
print -r -- "$import_out" | grep -q 'DRILL_IMPORT_OK'

print "PORTABLE_DRILL_PASS bytes=$(stat -f%z "$portable")"
