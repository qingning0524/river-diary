#!/bin/zsh
# T18：用合成敏感标记证明个人资料不会进入可分发包。
#
# 在干净检出中运行。脚本只在 .gitignore 覆盖的路径里植入合成标记，因此工作树
# 仍应保持 clean；随后构建 Mac/iOS Release 产物、模拟官网发布命令，并逐个扫描
# 标记是否泄漏。任何泄漏都以非零状态退出，退出时恢复植入文件。
#
# 用法：
#   scripts/verify_release_privacy.sh [--report <json>] [--skip-ios] [--keep]
#
# 退出码：0 通过；1 发现泄漏；65 前置条件不满足；70 构建失败。
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

report_path=""
skip_ios=0
keep_work_root=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) report_path="$2"; shift 2 ;;
    --skip-ios) skip_ios=1; shift ;;
    --keep) keep_work_root=1; shift ;;
    --help|-h) print -r -- "usage: $0 [--report <json>] [--skip-ios] [--keep]"; exit 0 ;;
    *) print -u2 "unknown argument: $1"; exit 64 ;;
  esac
done

fail() {
  print -u2 "FAIL: $1"
  exit "${2:-65}"
}

# 合成标记：可安全搜索的随机串，不会与真实内容撞车。
marker="RIVER_SYNTHETIC_SECRET_$(date -u +%Y%m%dT%H%M%SZ)_$(openssl rand -hex 6)"

snapshot_targets=(
  "data/data.json"
  "data/ios-user-data.json"
  "macos/RiverDiaryMac/Sources/RiverDiaryMac/Resources/data.json"
  "ios/RiverDiary/RiverDiary/Resources/data.json"
)

# 前置条件：不得覆盖真实个人资料，工作树必须 clean。
for target in "${snapshot_targets[@]}"; do
  if [[ -e "$target" ]]; then
    fail "拒绝覆盖已存在的 $target；请在干净检出（无个人资料）中运行本脚本。"
  fi
done
if [[ -n "$(git status --porcelain)" ]]; then
  fail "工作树不 clean；privacy 扫描需要可比对的冻结源码。先提交或清理后重跑。"
fi
commit="$(git rev-parse HEAD)"

work_root="$(mktemp -d "${TMPDIR%/}/RiverDiary-release-privacy.XXXXXX")"
cleanup() {
  for target in "${snapshot_targets[@]}"; do
    rm -f "$target" 2>/dev/null || true
  done
  if [[ "$keep_work_root" -eq 0 ]]; then
    rm -rf "$work_root" 2>/dev/null || true
  else
    print -r -- "Kept work root: $work_root"
  fi
}
trap cleanup EXIT

print -r -- "Synthetic marker: $marker"
print -r -- "Source revision:  $commit"
print -r -- "Work root:        $work_root"

# 1. 植入合成快照（全部位于 .gitignore 覆盖路径）。
for target in "${snapshot_targets[@]}"; do
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<JSON
{
  "syntheticClinicProbe": "$marker",
  "entries": [{"date": "1999-12-31", "text": "$marker"}]
}
JSON
done
print -r -- "Planted synthetic snapshots in ${#snapshot_targets[@]} local-only paths."

if [[ -n "$(git status --porcelain)" ]]; then
  fail "植入合成标记后工作树变脏；检查 .gitignore 是否覆盖了快照路径。"
fi

# 2. 构建 Mac Release 产物（make_app.sh 自带打包前拦截）。
source "$repo_root/scripts/select_xcode.sh" >/dev/null
mac_app="$work_root/mac/River Diary.app"
if ! ( cd macos/RiverDiaryMac && RIVER_APP_OUTPUT_DIR="$mac_app" \
        RIVER_BUILD_CONFIG=release ./make_app.sh ) > "$work_root/mac-build.log" 2>&1; then
  tail -20 "$work_root/mac-build.log" >&2
  fail "Mac Release 构建失败（日志：$work_root/mac-build.log）" 70
fi
print -r -- "Built Mac app: $mac_app"

# 3. 构建 iOS Release 模拟器产物。
ios_app=""
if [[ "$skip_ios" -eq 0 ]]; then
  ios_derived="$work_root/ios-derived"
  if ! xcodebuild -project ios/RiverDiary/RiverDiary.xcodeproj -scheme RiverDiary \
      -configuration Release -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "$ios_derived" build > "$work_root/ios-build.log" 2>&1; then
    tail -20 "$work_root/ios-build.log" >&2
    fail "iOS Release 构建失败（日志：$work_root/ios-build.log）" 70
  fi
  ios_app="$ios_derived/Build/Products/Release-iphonesimulator/RiverDiary.app"
  if [[ ! -d "$ios_app" ]]; then
    fail "找不到 iOS Release 产物：$ios_app" 70
  fi
  print -r -- "Built iOS app: $ios_app"
fi

# 4. 模拟官网发布：按 website/README 的命令排除本地 downloads/。
site_mirror="$work_root/site-mirror"
site_published="$work_root/site-published"
mkdir -p "$site_mirror/downloads" "$site_published"
rsync -a "$repo_root/website/site/" "$site_mirror/"
printf '%s' "$marker" > "$work_root/probe-payload.txt"
(cd "$work_root" && zip -q -j "$site_mirror/downloads/RiverDiary-macOS-synthetic-probe.zip" probe-payload.txt)
rsync -a --exclude='downloads/' "$site_mirror/" "$site_published/"
print -r -- "Mirrored website/site and applied the documented publish exclusion."

# 5. 扫描：任何命中都视为泄漏。
hits_total=0
typeset -a scan_results=()

scan_tree() {
  local label="$1" dir="$2"
  if [[ ! -e "$dir" ]]; then
    print -u2 "  FAIL  $label (missing: $dir)"
    return 1
  fi
  local hits count
  hits="$(/usr/bin/find "$dir" -type f -exec /usr/bin/grep -l -a -F "$marker" {} + 2>/dev/null || true)"
  if [[ -z "$hits" ]]; then
    count=0
  else
    count="$(print -r -- "$hits" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  fi
  hits_total=$(( hits_total + count ))
  scan_results+=("$label|$count|$dir|$hits")
  if [[ "$count" -eq 0 ]]; then
    print -r -- "  PASS  $label (0 hits)"
  else
    print -u2 "  LEAK  $label ($count hits)"
    print -r -- "$hits" | /usr/bin/sed -n '1,10p' >&2
  fi
  return 0
}

print -r -- "Scanning distributable artifacts for the synthetic marker..."
scan_tree "mac-app" "$mac_app" || fail "Mac app is missing" 70
if [[ -n "$ios_app" ]]; then
  scan_tree "ios-app" "$ios_app" || fail "iOS app is missing" 70
fi
scan_tree "published-site" "$site_published" || fail "Published site mirror is missing" 70

# 6. 反向对照：确认扫描器能发现真实存在于包内的标记。
control_dir="$work_root/control"
mkdir -p "$control_dir"
cp "$work_root/probe-payload.txt" "$control_dir/leak.txt"
control_hits="$(/usr/bin/find "$control_dir" -type f -exec /usr/bin/grep -l -a -F "$marker" {} + 2>/dev/null || true)"
if [[ -z "$control_hits" ]]; then
  fail "反向对照失败：扫描器未发现刻意植入的标记，扫描结论不可信。"
fi
print -r -- "  PASS  negative-control (scanner detects planted marker)"

# 7. 额外确认：源树中确实存在标记（证明扫描条件成立）。
planted_sources=0
for target in "${snapshot_targets[@]}"; do
  if [[ -n "$(/usr/bin/grep -l -a -F "$marker" "$target" 2>/dev/null || true)" ]]; then
    planted_sources=$(( planted_sources + 1 ))
  fi
done
if [[ "$planted_sources" -ne "${#snapshot_targets[@]}" ]]; then
  fail "只有 $planted_sources/${#snapshot_targets[@]} 个合成快照写入成功。" 70
fi

report_path="${report_path:-$repo_root/output/release-privacy-report.json}"
mkdir -p "$(dirname "$report_path")"
python3 - "$report_path" "$marker" "$commit" "$planted_sources" "$hits_total" "${scan_results[@]}" <<'PY'
import json, sys
from datetime import datetime, timezone

path, marker, commit, planted, hits_total = sys.argv[1:6]
rows = []
for entry in sys.argv[6:]:
    label, count, target, hits = entry.split("|", 3)
    rows.append({
        "label": label,
        "target": target,
        "markerHits": int(count) if count.isdigit() else count,
        "files": [line for line in hits.splitlines() if line],
    })
report = {
    "reportSchema": 1,
    "generatedAtUTC": datetime.now(timezone.utc).isoformat(),
    "sourceRevision": commit,
    "syntheticMarker": marker,
    "plantedSnapshotFiles": int(planted),
    "leakHitsTotal": int(hits_total),
    "scans": rows,
    "negativeControl": "detected",
    "verdict": "pass" if int(hits_total) == 0 else "leak",
}
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(f"Report written: {path}")
PY

if [[ "$hits_total" -ne 0 ]]; then
  fail "发现 $hits_total 处合成标记泄漏" 1
fi
print -r -- "PASS: no synthetic marker reached any distributable artifact ($planted_sources planted snapshots, 0 hits)."
