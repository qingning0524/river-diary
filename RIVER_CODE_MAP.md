# RIVER_CODE_MAP — 当前代码地图（重要目录与文件）

> 只读审计产物，日期：2026-09-19。
> 每个条目标注 目的 / 依赖 / 被谁使用 / 建议状态。
> 状态字典：KEEP（保留并纳入 V2）/ REFACTOR（保留但需要改）/ REPLACE（重写或替换）/ DELETE（删除）/ ARCHIVE（冻结保留，不进 macOS 主链路）。

---

## 1. macOS 根工程

### 1.1 入口与 Shell

| 文件 | 目的 | 主要依赖 | 使用方 | 状态 |
|---|---|---|---|---|
| `RiverDiaryMacApp.swift` | `@main`，创建 4 个 Store，主窗口 + 菜单栏快记 | 全部 Store | — | KEEP（改名/瘦身并后） |
| `RootView.swift` | 侧栏 + 五流向 + 启动门禁（AI 连接） | 全部 Store、Theme、AppLock | App | REFACTOR（拆依赖、移除 AI 硬门槛倾向） |
| `Views/FlowViews.swift` | 五流向容器 | Store | RootView | REFACTOR（大视图） |
| `Views/NavigationModels.swift` | 流向枚举 | — | RootView | KEEP |

### 1.2 App 层 Store（God Objects）

| 文件 | 目的 | 依赖 | 使用方 | 状态 |
|---|---|---|---|---|
| `DiaryStore.swift`（866 行） | 日记数据快照、外部文件监听、本地修改、加密持久化、备份恢复、AI 草稿合并 | AppDatabase 不依赖，依赖 StateEncryption、DataIngestion 注射 | 几乎所有视图 | REFACTOR → 拆 `DiaryRepository` + `LocalStateStore` + `SnapshotWatcher` |
| `ActivityStore.swift`（553 行） | 采集（事件）+ 持久化（.activity）+ 暂停调度 + 融合缓存 + 备份 + 屏幕时长 | AppKit、AX、StateEncryption、ActivityFusionEngine、ActivityClassifier、ActivityLifecycle | Today/时间线/洞察/隐私 | REFACTOR → 拆 `ActivityCollector` + `ActivityRepository` |
| `DataIngestionStore.swift`（753 行） | 定时采集 iOS/Chrome/Notes/屏幕、清洗、写 SQLite、导出、触发 AI | AppDatabase、ChromeHistoryReader、AppleNotesReader、ActivityStore、DiaryStore、AIAssistantStore、StateEncryption | 设置/自动记录 | REFACTOR → 拆 `IngestionScheduler` + `IngestionPipeline` + `RawEventStore` |
| `AIAssistantStore.swift`（1,410 行） | AI 配置、任务状态、网络、格式化、归档、记忆搜索 AI | URLSession、AIKeychain/AISecureKeyStore、AIModels、AppDatabase、DiaryStore、ActivityStore | 洞察/记忆/时间线 | REFACTOR → 拆 `AIProfileStore` + `AIChatClient` + `AITaskRunner` + `AnalysisArchive` |

### 1.3 领域模型与引擎

| 文件 | 目的 | 状态 |
|---|---|---|
| `ActivityModels.swift` | ActivitySession/SourceKind/Usage/FusedDay/FusedRange | KEEP（核心模型基础，需加证据链） |
| `ActivityClassifier.swift` | 应用 identity / category / focus / 图标色 | KEEP（纯逻辑，好测） |
| `ActivityTimeline.swift` | ActivityTimelineItem + Engine + Export | REFACTOR（并入 Episode 层） |
| `TimelineSegment.swift` | TimelineSegment + Engine | REFACTOR（并入 Episode 层） |
| `TimelineSegmentNames.swift` | 时段名称（上午/下午…） | KEEP |
| `ActivityFusionEngine.swift` | 双源融合 + 冲突/置信度 | REFACTOR（重复统计分散，收敛） |
| `ActivityConfidenceEngine.swift` | 置信度因素 | KEEP（思路好，需接入 provenance） |
| `ActivityInsightEngine.swift` | 相关度分析 | REFACTOR（并入 Context/本地分析） |
| `ActivityQuestionEngine.swift` | 自然语言日期范围解析 | KEEP（可复用） |
| `ActivityChatEngine.swift` | 本地足迹问答（无 AI） | KEEP（无 AI 也能用的确定性 Q&A） |
| `Models.swift` | DiaryData/DiaryEntry/QuickCapture/UserState/Overrides | REFACTOR（拆成 Entry & LocalState） |
| `DatabaseModels.swift` | DB 层 DTO | REPLACE（当前 DB 不可信，V2 重构） |
| `DailyCaptureModels.swift` | ChromeVisit/DailyNoteEntry/DailyCaptureRecord | REFACTOR → 并入 RawEvent DTO |
| `DataIngestionModels.swift` | iOS 导出 DTO | KEEP（迁移边界数据） |
| `MoodInsight.swift`（506 行） | 心情/健康关联分析 | REFACTOR |
| `LocalReview.swift` | 本机周期回顾 | KEEP（无 AI 回顾，方向对） |
| `JournalWriting.swift` | 草稿编辑合并 | KEEP（已有测试） |
| `MemoryArchive.swift` | 按天记忆归档 | REFACTOR（将来接 Memory 层） |
| `MemorySearch.swift` | 本地全文/日期搜索 | KEEP（确定性，作为 Ask 本地后端） |
| `MonthlyLetter.swift` | 河流信 | KEEP（用户文字，不删除） |
| `TimelineAnnotation.swift` | 时间整理注释 | KEEP（未来接入 Episode.provenance） |
| `ActivityLifecycle.swift` | 退出/终止保存 | KEEP |
| `Environment/SHA256Hex.swift` | 哈希 | KEEP |

### 1.4 存储

| 文件 | 目的 | 状态 |
|---|---|---|
| `AppDatabase.swift`（811 行） | SQLite 建表/迁移/查询，直接 SQL | REFACTOR → REPLACE schema；迁移策略必须先报告 |
| `AppDatabaseHistoricalImport.swift` | iOS 历史导入 | REFACTOR（并入 IngestionPipeline 写 RawEvent） |
| `DatabaseTime.swift` | ISO/短时间格式化 | KEEP |
| `StateEncryption.swift` | journal/activity/ingestion 的 AES 加密 | KEEP（统一加密助手，修复期减少重复） |
| `AIKeychain.swift` / `AIModels.swift` | AI 凭证与请求模型 | KEEP（凭证层需收敛成单一抽象） |

### 1.5 采集器（专门 Reader）

| 文件 | 目的 | 状态 |
|---|---|---|
| `ChromeHistoryReader.swift` | 只读复制+查询 Chrome History | KEEP（封装好，敏感源；需入隐私层） |
| `AppleNotesReader.swift` | 只读查询 Apple Notes | KEEP（封装好，敏感源；需入隐私层） |

### 1.6 视图

| 视图（核心大文件） | 目的 | 状态 |
|---|---|---|
| `Views/TodayView.swift`（252 行） | 今日日记 + 素材 | REFACTOR（V2 Today） |
| `Views/DayTimelineView.swift`（629 行） | 时间线 + 依据 | REFACTOR（V2 时间线，读 Episode） |
| `Views/TimelineSegmentCardView.swift`（290 行） | 时段卡片 | KEEP（小型化产出） |
| `Views/MemoryView.swift`（280 行） | 本地记忆搜索/归档 | REFACTOR（V2 Memory） |
| `Views/InsightView.swift`（227 行） | 洞察/本地回顾 | REFACTOR |
| `Views/ActivityView.swift`（508 行） | 洞察页活动细览 | REFACTOR |
| `Views/DataExplorerView.swift`（848 行） | 跨天查询/数据库页 | REFACTOR → 大幅瘦身；禁止 UI 直接读 DB |
| `Views/PrivacyView.swift`（800 行） | 隐私/备份 | REFACTOR → 数据源健康面板与权限诊断独立 |
| `Views/AIAnalysisView.swift`（687 行） | AI 分析卡 | REFACTOR（接 AnalysisArchive） |
| `Views/RhythmView.swift`（602 行） | 节律/月度回顾 | KEEP（保留，V2 顺势接入） |
| `Views/RootView.swift` | 主壳 | REFACTOR |
| 其余小视图（DateCard、Capture、LocalReview、Archive、Letter、Workspace…） | 支撑组件 | 多数 KEEP |

---

## 2. macOS 测试

| 文件 | 覆盖 | 状态 |
|---|---|---|
| `FeatureLogicTests.swift` | 保存/覆盖/旧评分 | KEEP |
| `ActivityFusionTests.swift` | 双源融合 | KEEP |
| `ActivityTimelineTests.swift` | 时间线 | KEEP |
| `ActivityLifecycleTests.swift` | 退出保存 | KEEP |
| `MemorySearchTests.swift` | 本地搜索 | KEEP |
| `MoodInsightTests.swift` | 心情分析 | KEEP |
| `MonthlyLetterTests.swift` | 河流信 | KEEP |
| `TimelineAnnotationTests.swift` | 整理 | KEEP |
| `TimelineSegmentTests.swift` | 时段 | KEEP |
| `ModelTests.swift` | 模型 | KEEP |
| `WorkspaceRefactorTests.swift` | 工作区合并 | KEEP |

**缺**：DB/SQL 测试、加密测试、AI 失败测试、Chrome/Notes 解析测试、保留策略删除测试。

---

## 3. Web（ARCHIVE，不在 macOS 主链路）

| 路径 | 目的 | 状态 |
|---|---|---|
| `index.html` / `src/css` / `src/js` | 单文件页 | ARCHIVE（保留历史对照） |
| `dist/` | 构建产物 | ARCHIVE |
| `css/style.css`、`js/app.js` | 生成产物 | DELETE（可再生成） |

---

## 4. Python 管道（ARCHIVE）

| 模块 | 目的 | 状态 |
|---|---|---|
| `pipeline/paths.py` / `io.py` | 路径与原子写 | ARCHIVE |
| `pipeline/records.py` | 清洗/汇总/质检 | ARCHIVE |
| `pipeline/health.py` | iOS 合并 | ARCHIVE |
| `pipeline/snapshots.py` | 每日 JSON/manifest | ARCHIVE |
| `pipeline/assets.py` / `runtime.py` | 打包 | ARCHIVE |
| `build.py` | 兼容入口 | ARCHIVE |
| `tests/` | 管道测试 | ARCHIVE |
| `data/raw.json` | 用户真实手写日记原文（gitignore） | KEEP-只读（迁移用户数据时处理，不能删） |

---

## 5. iOS（暂停，ARCHIVE）

| 文件 | 状态 | 备注 |
|---|---|---|
| `ios/RiverDiary/**/DiaryStore.swift`、`HealthKitStore.swift`、`ScreenTimeStore.swift`、`ICloudDriveStore.swift`、`BackgroundHealthSyncManager.swift` | ARCHIVE | 保留代码、不进 macOS 依赖；其 iCloud 导出仍是 macOS 一个数据源 |
| 其余 SwiftUI 视图与 Models | ARCHIVE | 继续暂停 |

---

## 6. 根目录其他

| 路径 | 状态 |
|---|---|
| `Makefile` | KEEP（修正 stream 验证脚本） |
| `README.md`、`docs/` | KEEP（V2 简介后更新） |
| `规划.md` | KEEP（产品路线参考） |
| `backups/` | ARCHIVE |
| `预览图/`、`.pdf`、`.doc` 等媒体 | ARCHIVE |
| `DesignArchive/` | DELETE（确认无引用后） |
| `data/raw.json`、`data/data.json`、`data/ios-user-data.json` | 见上（只读遗产） |

---

## 7. 状态总结（快速清单）

- KEEP（作为 V2 组件保留并通常需要接入新数据层）：
  ActivityModels、ActivityClassifier、ActivityTimeline、TimelineSegmentNames、ActivityConfidenceEngine、ActivityChatEngine、LocalReview、MemorySearch、JournalWriting、MonthlyLetter、TimelineAnnotation、ActivityLifecycle、ChromeHistoryReader、AppleNotesReader、StateEncryption、多数测试视图组件。
- REFACTOR（可复用但结构需收敛）：
  4 个巨型 Store、ActivityFusionEngine、ActivityInsightEngine、MoodInsight、MemoryArchive、Views 的大文件。
- REPLACE：
  `DatabaseModels.swift` 与 `AppDatabase` 的 schema（旧库日期不可信）、resources `data.json` 作为唯一数据源的角色。
- ARCHIVE（冻结、不进 macOS 主链路）：
  Web、Python 管道、iOS、`data/` JSON 遗产。
- DELETE（确认依赖后）：
  `DesignArchive/HomeView.swift.disabled`、`hermes` 残留分支、旧 `activity.state`/`health-snapshot.bin` 迁移路径。

> 任何 DELETE 必须先跑依赖检查，且不能触碰用户手写内容（`data/raw.json`、`journal.state` 内容）。
