#!/usr/bin/env zsh
# 把 D0 演示包、校验和、安装说明、试用清单与演示截图打成一个可直接发给种子用户的 zip。
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
dmg="${1:-$root/dist/RiverDiary-1.0.0-arm64-signed.dmg}"
[[ -f "$dmg" ]] || { print -u2 "missing DMG: $dmg (run make dmg-signed)"; exit 66; }
sha_file="$dmg.sha256"
[[ -f "$sha_file" ]] || { print -u2 "missing checksum: $sha_file"; exit 66; }

version="1.0.0"
stage="$(/usr/bin/mktemp -d "${TMPDIR%/}/river-sponsor-kit.XXXXXX")"
mnt="$(/usr/bin/mktemp -d "${TMPDIR%/}/river-sponsor-mnt.XXXXXX")"
cleanup() {
  /usr/bin/hdiutil detach "$mnt" >/dev/null 2>&1 || true
  /bin/rm -rf "$stage" "$mnt"
}
trap cleanup EXIT

mkdir -p "$stage/RiverDiary-D0"
cp "$dmg" "$stage/RiverDiary-D0/"
cp "$sha_file" "$stage/RiverDiary-D0/"
cp "$root/docs/operations/DEMO_QA_CHECKLIST.md" "$stage/RiverDiary-D0/试用清单.md"
if [[ -f "$root/output/analysis/mac-demo-data.png" ]]; then
  /usr/bin/sips -Z 1600 "$root/output/analysis/mac-demo-data.png" --out "$stage/RiverDiary-D0/演示截图.png" >/dev/null
fi

install_note="$root/dist/安装说明.txt"
if [[ -f "$install_note" ]]; then
  cp "$install_note" "$stage/RiverDiary-D0/安装说明.txt"
else
  # 兼容旧 dist：没有根目录安装说明时，从 DMG 里取。
  /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null
  if [[ -f "$mnt/安装说明.txt" ]]; then
    cp "$mnt/安装说明.txt" "$stage/RiverDiary-D0/安装说明.txt"
  fi
  /usr/bin/hdiutil detach "$mnt" >/dev/null
  trap - EXIT
  /bin/rm -rf "$mnt"
fi

cat > "$stage/RiverDiary-D0/先读我.txt" <<'TXT'
河流日记 D0 赞助演示包（macOS / Apple Silicon）

这个包只给种子用户/赞助者试用，不是正式发布版。
- 先看《安装说明.txt》：先核对 SHA-256，再右键 → 打开；被拦截时执行里面的 xattr 命令。
- 校验命令：在 DMG 与 .sha256 所在目录执行 `shasum -a 256 -c *.dmg.sha256`，看到 OK 才打开。
- 不要把这个包重新上传到公开网盘或应用市场。
- 反馈时只发版本、芯片、复现步骤；不要发日记正文、恢复码、API Key。
- 先写日记后绑定账号；不绑定也能用。绑定后本机资料归当前账号。
- 换 Mac 请用「设置 → 隐私与备份 → 可移植备份」和恢复码，不要只拿本机完整备份。
- 详细试用步骤见《试用清单.md》。

当前已知限制：
- 未公证；Gatekeeper 首次打开需要手动放行。
- 官方 AI 额度未开放，只有 BYOK（自己的 API Key）或本机模型。
- iOS 暂不提供安装包/TestFlight。
- Mac 完整备份依赖原钥匙串；跨机必须用可移植备份。
TXT

mkdir -p "$root/dist"
out="$root/dist/RiverDiary-D0-Sponsor-Kit-$version-$(date +%Y%m%d).zip"
(cd "$stage" && /usr/bin/zip -q -r -X "$out" RiverDiary-D0)
base="$(basename "$out")"
(cd "$(dirname "$out")" && /usr/bin/shasum -a 256 "$base" > "$base.sha256")
print "Created: $out"
print "SHA-256: $(cut -d' ' -f1 "$out.sha256")"
