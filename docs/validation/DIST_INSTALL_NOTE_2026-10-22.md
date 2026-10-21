# 分发安装说明与种子包补齐（2026-10-22）

状态：**dist 根目录与种子包已有完整安装说明；现有 DMG 二进制未重建。**

## 1. 交付物

| 文件 | 内容 |
|---|---|
| `dist/安装说明.txt` | 文件名、**实际 SHA-256**、`shasum -a 256 -c` 校验步骤、Gatekeeper 右键打开、`xattr` 命令、隐私与反馈 |
| `dist/RiverDiary-1.0.0-arm64-signed.dmg.sha256` | 改为**相对文件名**，不再写本机绝对路径，换目录后 `shasum -c` 仍可用 |
| `dist/RiverDiary-D0-Sponsor-Kit-1.0.0-20261022.zip` | 内含 DMG、`.sha256`、`安装说明.txt`、`先读我.txt`、试用清单与截图 |
| `dist/...zip.sha256` | 种子包自身的相对路径校验和 |

DMG 摘要：`cc29a8a1bbd486ec0fa0b0021a0ae357c4cf03fa54065c0d42a3c4f660ea5f64`
种子包摘要：`f52f70f82dcf26c7f934af8385641602b8381459f3684e8a0b22603dd2061c51`

## 2. 验证

```text
RiverDiary-1.0.0-arm64-signed.dmg: OK
RiverDiary-D0-Sponsor-Kit-1.0.0-20261022.zip: OK
```

- `dist/安装说明.txt` 的 SHA-256 与种子包内同名文件一致（`1f39ae8b…`）。
- 种子包内解压后执行 `shasum -a 256 -c RiverDiary-1.0.0-arm64-signed.dmg.sha256` 返回 `OK`。
- 证据：[安装说明副本](evidence/2026-10-22/distribution/安装说明.txt)、[校验输出](evidence/2026-10-22/distribution/checksums.txt)。

## 3. 生成脚本

- `scripts/make_mac_dmg.sh`：DMG 内说明新增 SHA 校验段；打包后生成 `dist/安装说明.txt`，其中写入实际摘要；`.sha256` 改为相对文件名。
- `scripts/make_sponsor_kit.sh`：优先使用 `dist/安装说明.txt`（不再必须挂载 DMG）；`先读我.txt` 增加校验命令；种子包 `.sha256` 改为相对路径。

## 4. 未验证 / 不能宣称

- **本次没有重建 DMG**：`hdiutil create` 在当前沙箱返回“目录非空/操作不被允许”，重建失败后已用备份恢复原 DMG（摘要未变）。因此：
  - `dist` 根目录说明与种子包内说明是**完整新版**；
  - 现有 DMG **内部**的 `安装说明.txt` 仍是旧版（有 Gatekeeper/xattr，但没有 SHA 段）；
  - `make_mac_dmg.sh` 的新内嵌文案与根目录说明生成逻辑只做了 `zsh -n` 语法检查，未在可创建 DMG 的环境实际跑通。
- 未在另一台 Mac 上实际走一遍 Gatekeeper 右键打开与 `xattr`；仍是本机验证。
- 未公证；说明里已明确此限制。

## 5. 需要 PM

- 若要 DMG 内部也带 SHA 段，需要在允许 `hdiutil` 的正常终端重跑 `make dmg-signed`；当前交付的 DMG 二进制可继续使用，校验以 `dist/安装说明.txt` 与 `.sha256` 为准。
