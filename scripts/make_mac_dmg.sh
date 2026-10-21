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
authority="$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1 | sed -nE 's/^Authority=(.*)$/\1/p' | head -1)"
if [[ -n "$authority" ]]; then
  signature_tag="signed"
  signature_line="签名：$authority（未公证）"
else
  signature_tag="adhoc"
  signature_line="签名：ad-hoc（每次重新构建可能变化；首次打开可能要求钥匙串授权）"
fi
name="RiverDiary-${version}-${arch}-${signature_tag}"
out="$repo_root/dist/${name}.dmg"
stage="$(/usr/bin/mktemp -d "${TMPDIR%/}/riverdmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

/usr/bin/ditto "$app" "$stage/River Diary.app"
ln -s /Applications "$stage/Applications"

cat > "$stage/安装说明.txt" <<TXT
河流日记 River Diary ${version}（赞助演示版 · ${arch}）
${signature_line}

系统要求
- macOS 14 或更高
- 当前包为 ${arch}；Intel Mac 暂不支持

先校验，再打开
- 收到 DMG 时，同目录应有一个同名 .sha256 文件：${name}.dmg.sha256。
- 在“终端”里进入该目录，执行：
  cd ~/Downloads
  shasum -a 256 -c ${name}.dmg.sha256
  看到 “OK” 才继续；校验失败不要打开，重新下载或联系发送者。
- 随包 .sha256 文件里应包含 ${name}.dmg 和 64 位十六进制摘要。

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
base="$(basename "$out")"
(cd "$(dirname "$out")" && /usr/bin/shasum -a 256 "$base" > "$base.sha256")
sum="$(cut -d' ' -f1 "$out.sha256")"

# 发给种子用户时，dist 根目录也放一份带实际摘要的安装说明；种子包会优先使用它。
cat > "$repo_root/dist/安装说明.txt" <<TXT
河流日记 River Diary ${version}（赞助演示版 · ${arch}）
${signature_line}

文件：${base}
SHA-256：${sum}

先校验，再打开
1. 把 DMG 和 ${base}.sha256 放在同一目录（例如 ~/Downloads）。
2. 在“终端”执行：
   cd ~/Downloads
   shasum -a 256 -c ${base}.sha256
3. 看到 “${base}: OK” 才打开；校验失败不要打开，重新下载或联系发送者。

安装
1. 双击 DMG，把「River Diary.app」拖到 Applications（或按住 Option 拖入用户 Applications）。
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

print "Created: $out"
print "SHA-256: $sum"
print "Install note: $repo_root/dist/安装说明.txt"
