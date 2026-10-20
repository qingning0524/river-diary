# T01 / T18 源码冻结、干净重建与发布隐私扫描

日期：2026-10-20（Asia/Shanghai）
状态：**T01 源头冻结与干净重建完成；T18 合成标记端到端扫描与空资料启动完成。**
仍需：iOS 单元测试 runner（T23）、生产安装包空账号交互复验、部署后生产核验。

## 1. 源码冻结（T01）

此前整个 v4.5 实现停留在未提交工作树，构建指纹只能绑定“脏工作树快照”，无法追溯。本轮按顺序冻结：

| 提交 | 内容 |
|---|---|
| `cf899bc` | v4.5 双端源码基线：Core / iOS / macOS / server / website / pipeline / docs / 图标库，共 8386 个文件；个人日记快照与构建产物仍由 `.gitignore` 排除 |
| `960b3c3` | 修复 `ObservedTimeDistributionTests` 的偶发失败（按 UUID 规范序比较证据集合） |
| `af4b903` | 新增 `scripts/verify_release_privacy.sh`、`scripts/verify_mac_empty_launch.sh` |
| `5bbe3e4` | 修复两个脚本在 `pipefail` 下的 SIGPIPE 中止问题 |

冻结后 `git status --porcelain` 为空。个人资料文件（`data/*.json`、两端 `Resources/data.json`、`archive/backups`、`archive/releases`、`archive/personal`、`dist/`、`output/`）确认未进入版本库。

## 2. 干净目录重建

验证方式：`git clone --local` 到全新临时目录，确认 `git status` 为空、无任何个人快照后执行构建与测试；不复制主工作区的构建缓存。

| 检查 | 结果 | 说明 |
|---|---|---|
| Python 管道测试 | 12 项通过 | `python3 -m unittest discover -s tests` |
| 网站控制台测试 | 35 项通过、0 跳过 | `website/user` Node 测试；`make test` 在干净检出通过 |
| Go 服务端（无数据库） | 62 顶层通过、38 跳过、0 失败 | 38 项因缺少 `TEST_DATABASE_URL` 跳过，不能算验证通过 |
| Go 服务端（隔离 PostgreSQL） | **62 顶层通过、0 跳过、0 失败** | 新增 `scripts/test_server_isolated.sh`：临时 `initdb` 集群 + 随机端口 + 跑完删除 |
| RiverDiaryCore | 54 项通过 | 修复前在 `cf899bc` 上 1/3 运行失败；修复后原过滤用例连续 10/10 通过 |
| macOS 测试 | 420 项通过、0 失败 | `scripts/test_macos_isolated.sh --disable-sandbox`，隔离临时用户目录 |
| macOS Release 打包 | 成功 | 隔离 scratch 目录构建；`make_app.sh` 打包前快照拦截生效 |
| iOS Release 模拟器构建 | 成功 | 隐私扫描脚本内完成 `-configuration Release -destination generic/platform=iOS Simulator` |
| iOS 单元测试 | **未运行通过** | `RiverDiaryTests` runner 在模拟器内挂起（`DTServiceHubClient failed to bless service hub`），与 2026-10-19 记录一致；属 T23 环境问题，不能记为通过 |

## 3. 发布隐私合成标记扫描（T18）

脚本：`scripts/verify_release_privacy.sh`（在干净检出中运行，任何泄漏非零退出）。

- 合成标记：`RIVER_SYNTHETIC_SECRET_20261020T050058Z_dfb9b0029606`
- 植入位置（全部位于 `.gitignore` 覆盖路径，植入后工作树仍 clean）：
  `data/data.json`、`data/ios-user-data.json`、
  `macos/RiverDiaryMac/Sources/RiverDiaryMac/Resources/data.json`、
  `ios/RiverDiary/RiverDiary/Resources/data.json`
- 源码版本：`5bbe3e4e`
- 构建：Mac Release app（`make_app.sh`）、iOS Release 模拟器 app
- 发布路径：按 `website/README.md` 的命令把 `website/site/` rsync 到镜像，排除本地 `downloads/`；另在镜像 `downloads/` 放入含标记的探针 ZIP

| 扫描目标 | 命中 |
|---|---|
| Mac Release app | 0 |
| iOS Release app | 0 |
| 官网发布镜像 | 0 |
| 反向对照（故意植入标记的文件） | 命中，证明扫描器有效 |

结论：4 个合成快照都没有进入任何可分发包或官网发布路径。报告：`docs/validation/evidence/2026-10-20/release-privacy-report.json`。

边界：该结果证明的是**本机构建与源码发布路径**；生产下载由管理台 `DOWNLOAD_DIR` 管理，部署后仍需按 §12 复核。

## 4. 空资料首次启动（T18）

脚本：`scripts/verify_mac_empty_launch.sh`。为不与已安装正式版的钥匙串条目冲突，脚本把 Release app 复制为 QA 变体（`studio.riverdiary.mac.qa`，使用 `.qa` 钥匙串命名空间），在临时用户目录中启动。

- 源码版本 `5bbe3e4e`；观察 12 秒：进程存活、无崩溃报告、主窗口出现（`River Diary`，1400×861）
- 报告：本目录 `mac-empty-launch-5bbe3e4.json`
- 首屏为欢迎/登录页（未登录、无资料），可以输入邮箱走验证码流程
- 启动后创建的文件（**登录前**）：
  - `Library/Application Support/RiverDiaryMac/Database/V2/river-v2.db`
  - `Library/Application Support/RiverDiaryMac/journal-encryption.key`

**发现（T02 输入）：** 首次启动、尚未绑定账号时就已经建立正式 V2 库和本机密钥。这与 §7.2 “首次未绑定不开正式库” 不一致，是 T02 延迟开库要解决的问题；本轮只取证，不在此处改生命周期。

**取证说明：** 窗口截图保存在本机 `/tmp/empty3.png`，因 macOS 自动填充把测试者邮箱预填进输入框，截图未纳入仓库。QA 与产品截图必须在关闭自动填充或在干净系统账户下重拍。

**环境发现（T23 输入）：** ad-hoc 重新签名的 QA 构建若遇到旧签名创建的 `.qa` 钥匙串条目，会弹系统授权框并卡住启动。脚本因此提供 `--reset-qa-keychain`（只清理 `.qa` 命名空间，不触碰正式密钥）。

## 5. 产物与路径

- 干净重建克隆：`/tmp/river-verify-20261020`（验证后保留在本机临时目录）
- 隐私报告：本目录 `release-privacy-report.json`
- Mac 构建指纹：本目录 `macos-release-provenance-clean-5bbe3e4.json`（`revision` = `5bbe3e4e…`，`workingTreeDirty: false`，182 个源文件，`codeDirectoryHash` = `4c96017b82f2a48c…`）；早先的 `macos-release-provenance.json` 仍绑定脏工作树，只作历史对照

## 6. 仍未完成

- iOS 单元测试 runner 连接问题未修复（T23），因此 iOS 仅证明“能构建成包”，未证明“测试通过”。
- 生产安装包在真实新用户/新 Mac 上的空资料首次启动仍需交互复验；本轮用 QA 变体与临时用户目录代替。
- PostgreSQL 集成已可本地全跑，但尚未接入 CI 或发布门禁流水线。
- 生产站点与下载服务的部署后核验（T18 剩余项）。
