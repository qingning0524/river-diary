#!/usr/bin/env zsh
# 生成赞助演示用 DMG。当前没有付费开发者账户，因此不做公证；
# 用安装说明把 Gatekeeper 的首次打开步骤讲清楚，并给出 SHA-256。
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$(pwd)"
app="${RIVER_APP_PATH:-$repo_root/dist/River Diary.app}"
[[ -d "$app" ]] || { print -u2 "Missing app: $app (run make mac first)"; exit 66; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || print 1.0.0)"
arch="$(/usr/bin/file "$app/Contents/MacOS/RiverDiary" | sed -nE 's/.*(arm64|x86_64).*/\1/p' | head -1)"
[[ -n "$arch" ]] || arch="unknown"
name="RiverDiary-${version}-${arch}"
out="$repo_root/dist/${name}.dmg"
stage="$(/usr/bin/mktemp -d "${TMPDIR%/}/riverdmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

/usr/bin/ditto "$app" "$stage/River Diary.app"
ln -s /Applications "$stage/Applications"

cat > "$stage/安装说明.txt" <<TXT
河流日记 River Diary ${version}（赞助演示版 · ${arch}）

系统要求
- macOS 14 或更高
- 当前包为 ${arch}；Intel Mac 暂不支持

安装
1. 把「River Diary.app」拖到 Applications（或按住 Option 拖入用户 Applications）。
2. 首次打开：在 Applications 里右键点击 River Diary → 打开 → 再点「打开」。
   如果系统提示“已损坏”或“无法验证开发者”，在终端执行：
   xattr -dr com.apple.quarantine "/Applications/River Diary.app"
   然后重新打开。
3. 第一次启动会直接创建本机日记，不需要注册账号。
   想使用官方 AI 额度、云副本或设备管理时，再到「设置 → 账号」绑定账号。

隐私
- 日记默认只在本机；本地功能不需要账号，也不依赖服务器。
- 未绑定账号也能写日记、自动记录、检索和备份。
- 这个版本没有经过 Apple 公证，所以首次打开需要上面的手动步骤；这是演示版的限制，不是病毒提示。

反馈
- 遇到问题请保留「设置 → 隐私与备份 → 导出诊断报告」，并记录 macOS 版本与芯片型号。
TXT

/usr/bin/hdiutil create -volname "River Diary" -srcfolder "$stage" -ov -format UDZO "$out" >/dev/null
/usr/bin/shasum -a 256 "$out" > "$out.sha256"
print "Created: $out"
print "SHA-256: $(cat "$out.sha256")"
