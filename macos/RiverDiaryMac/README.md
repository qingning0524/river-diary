# River Diary for macOS

本地优先的个人记忆原生应用。产品与开发唯一入口是 [主规划](../../主规划.md)，当前视觉规范见 [DESIGN](../../DESIGN.md)。AI参与获准范围的理解与整理，用户决定优先。

## 文件夹用途

`Sources/RiverDiaryMac/` 按功能与系统服务分类；Swift Package 会自动读取其中的 Swift 源码子目录。

最近的数据读写、记忆刷新和批量查询优化及验证见 [2026-10-06 代码优化记录](../../docs/changes/macos/MAC_CODE_OPTIMIZATION_2026-10-06.md)。

| 源码目录 | 用途 |
| --- | --- |
| `App/` | 应用启动、窗口控制与面向用户的错误提示。 |
| `Design/` | 设计规范、排版、主题与调色板。 |
| `Domain/` | V2 事实、活动、片段、记忆与分析的领域模型。 |
| `Features/Activity/` | 活动记录、分类、融合、可信度与事实投影。 |
| `Features/AI/` | AI 提供商、请求状态、统一分析上下文与调度。 |
| `Features/Diary/` | 日记模型、编辑草稿、保存、河流信与晚间提醒。 |
| `Features/Memory/` | 记忆档案、统一记忆库、本机检索与展示模型。 |
| `Features/Review/` | 日常回顾、习惯候选、确认与周期比较。 |
| `Features/Timeline/` | 时间线模型、片段、备注、摘要与依据关联。 |
| `Features/Health/` | 情绪与健康记录的本机洞察。 |
| `Infrastructure/Database/` | 兼容库、V2 事实库、历史导入、SQLCipher 与数据库模型。 |
| `Infrastructure/Security/` | 钥匙串、状态加密、文件保护与哈希工具。 |
| `Infrastructure/Ingestion/` | 浏览器、Apple Notes、位置、窗口与 iOS 导出数据采集。 |
| `Infrastructure/Sync/` | 设备同步设置、状态与诊断。 |
| `Infrastructure/Recovery/` | 备份恢复日志与恢复中断处理。 |
| `Infrastructure/QA/` | 测试与 QA 的临时数据目录隔离。 |
| `Views/` | 主窗口、各工作区、共享界面组件与设置页面。 |
| `Resources/` | 应用图标、第三方许可与内置数据快照。 |

包根的 `Package.swift` 定义依赖与目标，`Package.resolved` 固定依赖版本；`Tests/RiverDiaryMacTests/` 保存单元测试。`run.sh` 与 `make_app.sh` 分别负责开发运行与应用打包。`.build/`、`.swiftpm/` 是工具生成的本机缓存，业务数据库与密钥保存在用户的 Application Support 目录。

## 直接打开

```text
../../dist/River Diary.app
```

双击运行。重新打包：

```bash
./make_app.sh
```

## 当前五工作区

- **今天**：同日自动日记、事实摘要与来源状态；手动补充和评分可选。
- **足迹**：时间线、地点、健康在同一工作区；原始依据、用户纠正与日期上下文可达。
- **记忆**：跨日期归档/搜索、收藏与长期理解，编辑回顾时进入独立回顾工作区。
- **River**：围绕当前问题检索本机依据，按用户授权调用模型；输入区域保留在底部。
- **回顾**：周期回顾、待确认、习惯和进展；用户可自由回答并撤销决定。

来源管理、只读数据库和系统工具在原生设置。旧路由/命令可作为当前工作区的兼容捷径，不能据此恢复旧十三页侧栏。

共享日期和页面返回历史分别保持，编辑草稿不会因切页清空；保存失败保留文字。无AI时仍可读写日记、查原始资料和使用本机检索。双端同一结果、备份恢复与正式分发仍按主规划逐项验收。

## 验证

从项目根目录使用 `./scripts/test_macos_isolated.sh --disable-sandbox`；QA仅经 `scripts/launch_mac_qa.sh` 与独立临时Home启动，不能由Finder/LaunchServices重启后读取正式资料。当前清理与测试证据见 [整合记录](../../docs/maintenance/MASTER_PLAN_CONSOLIDATION_2026-10-19.md)。
