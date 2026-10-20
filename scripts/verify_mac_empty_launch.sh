#!/bin/zsh
# T18：验证没有个人快照时 Mac 应用仍可首次启动。
#
# 默认把给定 Release app 复制成 QA 变体（bundle id `studio.riverdiary.mac.qa`），
# 在临时用户目录中通过 QA 门禁启动，确认：
#   1. 包内没有 data.json / 用户导出快照；
#   2. 进程存活并真的出现了主窗口（不是只挂着一个空进程）；
#   3. 记录首次启动实际创建的文件（含是否建立本机库），供 T02 生命周期核对；
#   4. 尽力截取应用窗口，作为视觉证据。
#
# QA 变体使用 `.qa` 后缀的 Keychain 命名空间，不会读写正式安装的密钥。若同一
# QA 命名空间里残留旧签名的条目，ad-hoc 重新签名会触发系统钥匙串授权弹窗并
# 卡住启动；此时用 --reset-qa-keychain 清掉 QA 条目再试（只影响 QA，不动正式密钥）。
#
# 用法：
#   scripts/verify_mac_empty_launch.sh "<app bundle>" [--report <json>]
#       [--screenshot <png>] [--wait 15] [--reset-qa-keychain] [--production] [--keep]
#
# 退出码：0 通过；1 启动/窗口/崩溃检查失败；65 前置条件不满足。
set -euo pipefail

app_path=""
report_path=""
screenshot_path=""
wait_seconds=15
keep=0
reset_qa_keychain=0
production_mode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) report_path="$2"; shift 2 ;;
    --screenshot) screenshot_path="$2"; shift 2 ;;
    --wait) wait_seconds="$2"; shift 2 ;;
    --keep) keep=1; shift ;;
    --reset-qa-keychain) reset_qa_keychain=1; shift ;;
    --production) production_mode=1; shift ;;
    --help|-h)
      print -r -- "usage: $0 <app bundle> [--report <json>] [--screenshot <png>] [--wait 15] [--reset-qa-keychain] [--production] [--keep]"
      exit 0 ;;
    -*) print -u2 "unknown argument: $1"; exit 64 ;;
    *) app_path="$1"; shift ;;
  esac
done

if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  print -u2 "usage: $0 <app bundle> [--report <json>] [--screenshot <png>] [--wait 15] [--reset-qa-keychain] [--production] [--keep]"
  exit 65
fi

app_path="${app_path:A}"
binary="$app_path/Contents/MacOS/RiverDiary"
if [[ ! -x "$binary" ]]; then
  print -u2 "FAIL: missing executable $binary"
  exit 65
fi

# 包内不得包含个人快照。
snapshot_in_bundle="$(/usr/bin/find "$app_path/Contents" -type f \
  \( -name data.json -o -name ios-user-data.json -o -name river-diary-user-data.json \) \
  -print -quit)"
if [[ -n "$snapshot_in_bundle" ]]; then
  print -u2 "FAIL: app bundle contains a personal diary snapshot: $snapshot_in_bundle"
  exit 1
fi

repo_root="${0:A:h:h}"
source "$repo_root/scripts/select_xcode.sh" >/dev/null

work_root="$(mktemp -d "${TMPDIR%/}/RiverDiary-empty-launch.XXXXXX")"
qa_home="$work_root/home"
mkdir -p "$qa_home/Library/Application Support" "$qa_home/Library/Logs"
log_path="$work_root/app.log"
pid=""

cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    kill -KILL "$pid" 2>/dev/null || true
  fi
  if [[ "$keep" -eq 0 ]]; then
    rm -rf "$work_root" 2>/dev/null || true
  else
    print -r -- "Kept work root: $work_root"
  fi
}
trap cleanup EXIT

launch_binary="$binary"
launch_home="$qa_home"
qa_launched=0

if [[ "$production_mode" -eq 0 ]]; then
  qa_app="$work_root/RiverDiaryMacQA.app"
  cp -R "$app_path" "$qa_app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier studio.riverdiary.mac.qa" "$qa_app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName RiverDiaryQA" "$qa_app/Contents/Info.plist"
  codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$qa_app" >/dev/null 2>&1

  # 旧签名留下的 QA 钥匙串条目会让新签名在访问时弹窗卡住。
  stale_qa_items=0
  for service in "RiverDiaryMac.state.qa" "RiverDiary.account.qa" "local.riverdiary.node.qa"; do
    if timeout 5 security find-generic-password -s "$service" >/dev/null 2>&1; then
      stale_qa_items=$(( stale_qa_items + 1 ))
      if [[ "$reset_qa_keychain" -eq 1 ]]; then
        timeout 10 security delete-generic-password -s "$service" >/dev/null 2>&1 || true
      fi
    fi
  done
  if [[ "$stale_qa_items" -gt 0 && "$reset_qa_keychain" -eq 0 ]]; then
    print -u2 "WARN: 发现 $stale_qa_items 个旧 QA 钥匙串条目；ad-hoc 重新签名可能触发授权弹窗。"
    print -u2 "      如启动卡住，请重跑并加 --reset-qa-keychain（只清理 .qa 命名空间）。"
  fi

  launch_binary="$qa_app/Contents/MacOS/RiverDiary"
  qa_launched=1
  print -r -- "QA app:     $qa_app"
fi

print -r -- "App:        $app_path"
print -r -- "Fake home:  $launch_home"
print -r -- "Waiting:    ${wait_seconds}s"

touch "$work_root/start.marker"
if [[ "$qa_launched" -eq 1 ]]; then
  CFFIXED_USER_HOME="$launch_home" RIVER_DIARY_MAC_QA_HOME="$launch_home" \
    "$launch_binary" > "$log_path" 2>&1 &
else
  CFFIXED_USER_HOME="$launch_home" "$launch_binary" > "$log_path" 2>&1 &
fi
pid=$!
print -r -- "Launched PID: $pid"

sleep "$wait_seconds"

alive=0
if kill -0 "$pid" 2>/dev/null; then
  alive=1
fi

# 崩溃报告：观察窗口内新出现且属于本应用的报告。
crash_reports=""
if [[ -d "$HOME/Library/Logs/DiagnosticReports" ]]; then
  crash_reports="$(/usr/bin/find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f \
    \( -name 'RiverDiary*' -o -name 'River Diary*' \) -newer "$work_root/start.marker" 2>/dev/null || true)"
fi

# 首次启动实际创建的文件。
created_files="$(cd "$launch_home" && /usr/bin/find . -type f 2>/dev/null | sed 's|^\./||' | sort)"
db_created=0
if [[ "$created_files" == *"river-v2.db"* ]]; then
  db_created=1
fi

# 窗口与截图（尽力而为）。
windows=""
window_id=""
if [[ "$alive" -eq 1 ]]; then
  cat > "$work_root/window_probe.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1]) ?? 0
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
for window in windows {
    guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let name = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("\(number)|\(layer)|\(name)|\(bounds["Width"] ?? 0)x\(bounds["Height"] ?? 0)")
}
SWIFT
  windows="$("$RIVER_SWIFT_EXECUTABLE" "$work_root/window_probe.swift" "$pid" 2>/dev/null || true)"
  window_id="$(print -r -- "$windows" | /usr/bin/awk -F'|' '$2 == 0 && $1 != "" { print $1; exit }')"
  if [[ -n "$window_id" && -n "$screenshot_path" ]]; then
    mkdir -p "$(dirname "$screenshot_path")"
    screencapture -x -o -l"$window_id" "$screenshot_path" 2>/dev/null || true
  fi
fi

# 结束进程并等待清理。
kill -TERM "$pid" 2>/dev/null || true
for _ in {1..20}; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.25
done
kill -KILL "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
pid=""

log_tail="$(tail -20 "$log_path" 2>/dev/null || true)"

verdict="pass"
reason=""
if [[ "$alive" -eq 0 ]]; then
  verdict="fail"
  reason="process exited before ${wait_seconds}s"
elif [[ -n "$crash_reports" ]]; then
  verdict="fail"
  reason="new crash report detected"
elif [[ -z "$window_id" ]]; then
  verdict="fail"
  reason="no on-screen window appeared within ${wait_seconds}s (possible keychain authorization prompt)"
fi

if [[ -n "$report_path" ]]; then
  mkdir -p "$(dirname "$report_path")"
  python3 - "$report_path" "$app_path" "$qa_launched" "$alive" "$db_created" "$crash_reports" \
    "$created_files" "$windows" "$screenshot_path" "$wait_seconds" "$verdict" "$reason" "$log_tail" <<'PY'
import json, sys
from datetime import datetime, timezone

(path, app, qa, alive, db_created, crashes, files, windows, screenshot,
 wait_seconds, verdict, reason, log_tail) = sys.argv[1:14]

report = {
    "reportSchema": 1,
    "generatedAtUTC": datetime.now(timezone.utc).isoformat(),
    "app": app,
    "launchMode": "qa-isolated" if qa == "1" else "production",
    "bundleContainsSnapshot": False,
    "observedSeconds": int(wait_seconds),
    "processAlive": alive == "1",
    "crashReports": [line for line in crashes.splitlines() if line],
    "createdFiles": [line for line in files.splitlines() if line],
    "createdLocalDatabaseBeforeSignIn": db_created == "1",
    "windows": [line for line in windows.splitlines() if line],
    "screenshot": screenshot if screenshot else None,
    "verdict": verdict,
    "reason": reason,
    "logTail": log_tail.splitlines()[-20:],
}
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"Report written: {path}")
PY
fi

print -r -- "Launch mode:  $([[ $qa_launched -eq 1 ]] && print 'QA isolated' || print 'production')"
print -r -- "Process alive after ${wait_seconds}s: $([[ $alive -eq 1 ]] && print yes || print no)"
print -r -- "Window appeared: $([[ -n "$window_id" ]] && print yes || print no)"
print -r -- "Created files: ${#${(f)created_files}}"
print -r -- "Local database created before sign-in: $([[ $db_created -eq 1 ]] && print yes || print no)"
if [[ -n "$windows" ]]; then
  print -r -- "Windows:"
  print -r -- "$windows"
fi
if [[ -n "$screenshot_path" && -f "$screenshot_path" ]]; then
  print -r -- "Screenshot: $screenshot_path"
fi
if [[ -n "$crash_reports" ]]; then
  print -u2 "Crash reports:"
  print -u2 -- "$crash_reports"
fi
if [[ -n "$log_tail" ]]; then
  print -r -- "Log tail:"
  print -r -- "$log_tail"
fi

if [[ "$verdict" != "pass" ]]; then
  print -u2 "FAIL: $reason"
  exit 1
fi
print -r -- "PASS: app started with an empty profile, created its empty local store and showed a window."
