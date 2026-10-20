#!/bin/zsh
# 统一发布门禁：在干净检出里跑完所有关键验证，任何“没跑”都按失败处理。
#
# 这是主规划 T01 要求的“关键 skip 门禁”：发布前必须同时满足
#   - Python/网站/Go（隔离 PostgreSQL，0 skip）/Core/macOS 测试全过
#   - iOS 单元测试真的运行并通过（runner 未修复时必须显式 --allow-unrun-ios）
#   - 合成敏感标记扫描 0 命中
#
# 用法：
#   scripts/release_gate.sh [--report <json>] [--allow-unrun-ios]
#                           [--run-ios-tests] [--skip-privacy]
#
# 退出码：0 全部门禁通过；1 有失败或未验证；65 前置条件不满足。
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

report_path=""
allow_unrun_ios=0
run_ios_tests=0
skip_privacy=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) report_path="$2"; shift 2 ;;
    --allow-unrun-ios) allow_unrun_ios=1; shift ;;
    --run-ios-tests) run_ios_tests=1; shift ;;
    --skip-privacy) skip_privacy=1; shift ;;
    --help|-h)
      print -r -- "usage: $0 [--report <json>] [--allow-unrun-ios] [--run-ios-tests] [--skip-privacy]"
      exit 0 ;;
    *) print -u2 "unknown argument: $1"; exit 64 ;;
  esac
done

if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "FAIL: 工作树不 clean；门禁必须在冻结提交上运行。"
  exit 65
fi
commit="$(git rev-parse HEAD)"
source "$repo_root/scripts/select_xcode.sh" >/dev/null

work_root="$(mktemp -d "${TMPDIR%/}/RiverDiary-release-gate.XXXXXX")"
typeset -a step_names=()
typeset -a step_status=()
typeset -a step_notes=()

cleanup() {
  rm -rf "$work_root" 2>/dev/null || true
}
trap cleanup EXIT

record() {
  step_names+=("$1")
  step_status+=("$2")
  step_notes+=("$3")
  case "$2" in
    pass) print -r -- "PASS        $1${3:+ — $3}" ;;
    unverified) print -u2 "UNVERIFIED  $1${3:+ — $3}" ;;
    *) print -u2 "FAIL        $1${3:+ — $3}" ;;
  esac
}

run_simple_step() {
  local name="$1"
  shift
  local log="$work_root/$name.log"
  print -r -- ""
  print -r -- "== $name =="
  if "$@" > "$log" 2>&1; then
    local summary=""
    summary="$(grep -E 'Test run with [0-9]+ tests|Executed [0-9]+ tests|# pass [0-9]+|^Ran [0-9]+ tests|Top-level tests passed' "$log" \
      | grep -v 'Test run with 0 tests' | tail -1 || true)"
    record "$name" "pass" "$summary"
  else
    tail -15 "$log" >&2
    record "$name" "fail" "见 $name.log"
  fi
}

print -r -- "Release gate on $commit"

run_simple_step "python-node" make test
run_simple_step "core-tests" zsh -c 'source scripts/select_xcode.sh >/dev/null && swift test --package-path Packages/RiverDiaryCore'
run_simple_step "mac-tests" ./scripts/test_macos_isolated.sh --disable-sandbox
run_simple_step "server-tests" ./scripts/test_server_isolated.sh

# macOS 测试必须真的执行了用例，且没有跳过。
if [[ -f "$work_root/mac-tests.log" ]]; then
  mac_line="$(grep -E 'Executed [0-9]+ tests, with' "$work_root/mac-tests.log" | tail -1)"
  mac_count="$(print -r -- "$mac_line" | sed -nE 's/.*Executed ([0-9]+) tests.*/\1/p')"
  if [[ -z "$mac_count" || "$mac_count" -eq 0 ]]; then
    record "mac-tests-cover" "fail" "没有执行任何 macOS 用例"
  elif grep -q "skipped" "$work_root/mac-tests.log"; then
    record "mac-tests-cover" "fail" "macOS 测试出现 skipped"
  else
    record "mac-tests-cover" "pass" "$mac_count 项"
  fi
fi

run_simple_step "ios-test-build" xcodebuild -project ios/RiverDiary/RiverDiary.xcodeproj \
  -scheme RiverDiaryTests -configuration Debug -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$work_root/ios-tests-build" build-for-testing

if [[ "$run_ios_tests" -eq 1 ]]; then
  destination="${RIVER_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
  run_simple_step "ios-tests" ./scripts/test_ios_isolated.sh "$destination"
elif [[ "$allow_unrun_ios" -eq 1 ]]; then
  record "ios-tests" "unverified" "本轮显式允许不运行（T23 runner 未修复）"
else
  record "ios-tests" "unverified" "未运行；发布门禁默认拒绝。确需跳过请显式加 --allow-unrun-ios"
fi

if [[ "$skip_privacy" -eq 0 ]]; then
  run_simple_step "privacy-scan" ./scripts/verify_release_privacy.sh --report "$work_root/privacy-report.json"
else
  record "privacy-scan" "unverified" "本轮显式跳过"
fi

failures=0
unverified=0
for i in {1..${#step_names[@]}}; do
  case "${step_status[$i]}" in
    fail) failures=$(( failures + 1 )) ;;
    unverified) unverified=$(( unverified + 1 )) ;;
  esac
done

if [[ -n "$report_path" ]]; then
  mkdir -p "$(dirname "$report_path")"
  steps_tsv="$work_root/gate-steps.tsv"
  : > "$steps_tsv"
  for i in {1..${#step_names[@]}}; do
    safe_note="${step_notes[$i]//$'\n'/ }"
    safe_note="${safe_note//$'\t'/ }"
    print -r -- "${step_names[$i]}	${step_status[$i]}	${safe_note}" >> "$steps_tsv"
  done
  python3 - "$report_path" "$commit" "$failures" "$unverified" "$steps_tsv" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, commit, failures, unverified, steps_path = sys.argv[1:6]
steps = []
with open(steps_path, encoding="utf-8") as handle:
    for line in handle:
        name, status, note = (line.rstrip("\n").split("\t") + ["", ""])[:3]
        steps.append({"name": name, "status": status, "note": note})
report = {
    "reportSchema": 1,
    "generatedAtUTC": datetime.now(timezone.utc).isoformat(),
    "sourceRevision": commit,
    "failures": int(failures),
    "unverified": int(unverified),
    "verdict": "pass" if int(failures) == 0 and int(unverified) == 0 else "blocked",
    "steps": steps,
}
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"Report written: {path}")
PY
fi

print -r -- ""
if [[ "$failures" -gt 0 ]]; then
  print -u2 "GATE FAILED: $failures 步失败，$unverified 步未验证"
  exit 1
fi
if [[ "$unverified" -gt 0 ]]; then
  print -u2 "GATE NOT GREEN: 全部已跑步骤通过，但仍有 $unverified 步没有验证"
  exit 1
fi
print -r -- "GATE PASSED: 所有关键验证都实际运行并通过"
