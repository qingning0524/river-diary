#!/usr/bin/env zsh
# 扫描所有本机构建产物，确保没有把个人日记快照打进 .app。
# 源码里的 Resources/data.json 是开发机的忽略文件；它不应出现在任何 .app 内。
set -euo pipefail

repo_root="${0:A:h:h}"
cd "$repo_root"

forbidden=(data.json ios-user-data.json river-diary-user-data.json)
failures=0

while IFS= read -r app; do
  for name in "${forbidden[@]}"; do
    while IFS= read -r hit; do
      print -u2 "FAIL: personal snapshot inside build product: $hit"
      failures=$((failures + 1))
    done < <(find "$app" -type f -name "$name" -print 2>/dev/null)
  done
done < <(find ios macos dist -type d -name '*.app' -prune -print 2>/dev/null)

if (( failures > 0 )); then
  print -u2 "Build privacy scan failed: $failures file(s). Clean the build directory and rebuild; never ship a .app containing a personal snapshot."
  exit 1
fi

print "Build privacy scan passed: no personal snapshot in any .app."
