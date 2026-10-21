# River Diary 河流日记

本地优先的个人记忆产品：把生活片段、用户原话与可纠正的理解放在一处。Mac 使用 SQLCipher，iOS 使用系统文件保护，跨设备复制使用加密对象。产品与开发唯一入口是 [主规划](主规划.md)，视觉规范见 [DESIGN.md](DESIGN.md)。

iOS 当前采用已确认的五页拟态设计：**今天 / 足迹 / 待确认 / River / 我的**。自动记录与自动日记为主线；共用顶部日期，页面标题随内容滚动。版本来源及本轮底层修复见 [iOS 构建基线](ios/BUILD_BASELINE.md)，页面细节见 [五页实现说明](ios/IMPLEMENTATION.md)。

## 目录结构

完整的文件夹用途、源码分类与存放规则见 [目录说明](目录说明.md)；专项资料见 [文档索引](docs/README.md)。

| 路径 | 内容 |
|---|---|
| `macos/RiverDiaryMac/` | macOS 主应用（Swift Package，SwiftUI + SQLCipher） |
| `ios/RiverDiary/` | iOS 应用、Xcode 工程及隔离 QA 目标 |
| `Packages/RiverDiaryCore/` | 两端共享的事件、分析、同步与加密复制能力 |
| `server/` | FlowRiver 账号 API（Go + PostgreSQL），含 OpenAPI、迁移和部署模板；状态见 [`server/README.md`](server/README.md) |
| `website/` | 官网（flowriver.xyz/www）、登录页（login）、MemoryOS 用户控制台（user）与 Caddy 网关配置；见 [`website/README.md`](website/README.md) |
| `web-preview/` | 原有日记网页模板、CSS/JS 源文件及生成资源 |
| `pipeline/`、`build.py` | 本地数据清洗、快照与网页构建管道 |
| `data/` | 本机项目数据与构建状态，不纳入 Git |
| `scripts/` | 工具链选择、隔离测试、QA 启动、开发包验证及缓存清理 |
| `tests/` | Python 管道测试；原生测试保留在各平台项目内 |
| `图标素材库/` | River Glyph v2：一套 80 枚图标双端共用，含四状态 SVG/PNG、共享 Xcode 资源、应用图标与图录 |
| `docs/` | 架构、运维、验收、变更与设计资料；当前规划仅在根目录 |
| `dist/` | 当前 Mac 安装包、网页与每日快照产物 |
| `output/` | QA 证据与导出结果 |
| `archive/` | 历史备份、旧安装包、旧设计源稿与个人创作资料 |
| [主规划.md](主规划.md) | 产品、AI、功能、任务依赖与验收的唯一有效规划 |

## 构建与测试

```bash
# 全量 XCTest（需要 ~/Downloads/Xcode-beta.app，scripts/select_xcode.sh 自动选择）
./scripts/test_macos_isolated.sh --disable-sandbox

# 重建发布包到 dist/
make mac

# 开发包快速验证（发布构建 + 静态检查 + XCTest）
./scripts/verify_dev_build.sh

# 后端单元与本地 PostgreSQL 集成检查（需 Go 1.27+）
(cd server && go test -race ./...)
(cd server && TEST_DATABASE_URL='postgres://flowriver:local-only-change-this@127.0.0.1:5432/flowriver_test?sslmode=disable' go test -race -count=1 ./...)

# 用户记忆控制台前端测试（Node 内置测试，无需 npm）
make user-console-test

# 缓存清理：先预览，再执行；Xcode 测试结果会先转存
make clean-preview
make clean
```

完整数据构建会更新项目快照，并在 iCloud 目录存在时尝试同步；仅运行管道测试可使用 `python3 -m unittest discover -s tests`。清理缓存后，下一次原生构建或后台前端构建会重新生成缓存并可能下载依赖。

账号入口与核心并发保护已有实现；平台资料生命周期、恢复和剩余验收统一见 [主规划](主规划.md)。

Ubuntu 24.04 的逐步操作说明见 [服务器落地教程](docs/operations/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md)。

后台实现与 HTTP 接口见 [管理员后台设计与落地状态](docs/architecture/FLOWRIVER_ADMIN_CONSOLE_DESIGN.md)。管理员界面和 API 已接入；既有部署记录与真正异机日志/恢复演练分开，后续门槛见总规划 T17。

## 用户记忆控制台

`website/user/` 已重写为 MemoryOS 只读窗口：记忆首页 / 长河 / 合集 / 地点 / 理解 / 问 River / 账号与设置。用户可以导入由原生 App 导出的本地 JSON 副本，在浏览器里重读文字、地点、章节与理解卡；账号服务默认只处理身份、设备、权益与反馈，正文不上传。用户也可以主动开启端到端加密云空间，把只读副本加密后保存到账号服务，以便另一台设备用同一口令取回；服务端只保存密文，无法解密。当前源码在 Mac「设置 → 隐私与备份 → 网页控制台副本」和 iPhone「设置 → 导出我的记录 → 网页控制台」提供网页可读 JSON 导出；Mac app 构建通过，iOS 源码 SwiftPM 编译通过，完整 Xcode bundle 与完整记忆镜像仍待 T12。

线上：<https://user.flowriver.xyz/>（演示预览 <https://user.flowriver.xyz/?preview=1>）。本地预览：

```sh
cd website/user && python3 -m http.server 8099
# 打开 http://127.0.0.1:8099/?preview=1 查看合成演示
```

实现状态为 **前端完成、原生导出与真实账号/副本联调待验（T44）**；契约与边界见 [控制台架构](docs/architecture/USER_MEMORY_CONSOLE_2026-10-20.md)，验收见 [控制台验收](docs/validation/USER_MEMORY_CONSOLE_2026-10-20.md)。

## 当前产品与开发路线

[主规划](主规划.md)统一全部取舍。当前（v5.0，2026-10-21）进入 **D 赞助演示版**：先做本地优先的 Mac 演示包、网页预览和爱发电/自媒体赞助闭环，赞助期不买开发者账户、不上架；赞助验证通过后再走 M0 → M1 → M2 → M3 → M5（正式发布）。AI 采用 BYOK + 可选官方额度；用户先写日记，账号绑定可选。M4 对启用的 AI 理解/记忆能力独立评估。

AI定位建议为可积累、可纠正的个人记忆伙伴；先理解经历、采用用户纠正，再推进跨时间问答、章节和有限资料代理。旧平台/账号/学习/模型迁移草案已合并，具体任务使用同一组T01–T45。

[River验收](docs/validation/RIVER_DIARY_ACCEPTANCE.md)、[账号验收](docs/validation/BACKEND_ACCOUNT_ACCEPTANCE.md)与[日期审查](docs/validation/DUAL_END_AUDIT_2026-10-19.md)记录证据，不构成另一份规划；历史通过不能代表当前全绿。本次清理范围和恢复位置见[整合记录](docs/maintenance/MASTER_PLAN_CONSOLIDATION_2026-10-19.md)。

## 改动前必读

- 设计系统与验收清单：`DESIGN.md`（面板体系、色彩/字号/间距 token、8 条检查规则）。颜色、字号、间距一律用 token，不写裸值。
- 数据安全基线：SQLite 文本绑定必须用 SQLITE_TRANSIENT；无法解密的本地文件只隔离、不删除；内存修改在持久化成功前必须可回滚。
- 测试跑全绿再打包；`docs/validation/DEV_BUILD_STATUS.md` 记录每轮验证结论。
