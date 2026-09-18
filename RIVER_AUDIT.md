# RIVER_AUDIT — River 项目现状审计

> 只读审计快照，日期：2026-09-19。
> 本文件是第一阶段（审计）产物。审计范围是全仓库，重点是 `macos/RiverDiaryMac`。
> 审计期间未修改任何源代码；仅以官方工具链验证过 macOS Debug 构建与测试。

---

## 1. 项目总览

这是一个“三端同源”的本地优先日记项目：

| 端 | 位置 | 角色 |
|---|---|---|
| Web | `index.html` / `src/` / `dist/` | 单文件页面，读取管道生成的 `data/data.json` |
| iOS | `ios/RiverDiary` | SwiftUI 消费端，健康/评分穿戴端，通过 iCloud 文件同步到 Mac |
| macOS | `macos/RiverDiaryMac` | 本次核心。SwiftUI 应用 + 本机采集 + SQLite + AI 接入 |
| 数据管道 | `pipeline/` + `tests/` | 构建期清洗、合并、生成数据快照 |

项目当前定位是“情绪日记 + 足迹时间线 + 本地记忆搜索 + 可选 AI 洞察”。
与目标“Personal Memory OS”之间，已有大量可复用的数据采集与 UI 资产，
但缺少明确的 RawEvent → Activity → Episode → Memory → Context 分层。

### 代码规模

| 区域 | 文件数 | 行数 |
|---|---|---|
| macOS Sources（含 Views） | 70 个 `.swift` | 约 17,068 |
| macOS Tests | 12 个 `.swift` | 1,313 |
| iOS | 19 个 `.swift` | 2,667 |
| Web（`src/js` + `src/css`） | 18 + 7 | 4,392 |
| Python 管道 | 8 | 482 |
| Python 测试 | 2 | 197 |

### macOS 单文件 Top 8（行数，God Object 集中地）

| 文件 | 行数 |
|---|---|
| `AIAssistantStore.swift` | 1,410 |
| `DiaryStore.swift` | 866 |
| `AppDatabase.swift` | 811 |
| `DataIngestionStore.swift` | 753 |
| `ActivityStore.swift` | 553 |
| `MoodInsight.swift` | 506 |
| `ActivityFusionEngine.swift` | 440 |
| `Theme.swift` | 398 |

---

## 2. Target / 平台

- 工程目标：`macOS 14+`，SwiftPM（`swift-tools-version 5.9`），SwiftUI。
- 当前实际构建工具链（项目 Makefile 固定）：Xcode-beta `/Users/fa1lingdown/Downloads/Xcode-beta.app`。
- 已验证：在指定工具链下 `swift build --disable-sandbox` 成功，`swift test` 80 项全部通过。
- 直接运行 `swift build`（CommandLineTools）会因 SDK/编译器版本不匹配失败，与代码无关，是环境问题。
- iOS / Web / Python 管道仍在同一个仓库中但已不属于本次 scope。

---

## 3. Dependencies

**macOS**
- 无第三方 SwiftPM 依赖。
- 系统框架：SwiftUI、AppKit、Combine、CryptoKit、ApplicationServices（辅助功能窗口标题）、SQLite3（`~/.sqlite3`）、Security（钥匙串）。
- 无大型接入层，无网络库；AI 直接使用 `URLSession`。

**Web / Python**
- Web 零依赖（原生 HTML/CSS/JS）。
- Python 仅标准库（`unittest`、`json`、`pathlib`）。

**iOS**
- SwiftUI、HealthKit、iCloud 文件（`ICloudDriveStore`）。

> 结论：依赖面极窄，这是本项目的优点。不要为了 V2 引入大型依赖。

---

## 4. Database

### 4.1 macOS SQLite（`~/Library/Application Support/RiverDiaryMac/Database/river-diary.db`）

表：

| 表 | 作用 |
|---|---|
| `daily_records` | 每日聚合（评分/睡眠/运动/屏幕/计数/混合综述） |
| `mood_scores` | 单日评分 |
| `sleep_nights` | 睡眠 |
| `exercise_days` | 运动 |
| `chrome_visits` | 浏览器访问明细 |
| `daily_notes` | Apple Notes 标题 |
| `activity_sessions` | 实时片段副本 |
| `quick_captures` | 快记 |
| `ai_results` | AI 分析留档 |

索引：`chrome_visits`、`daily_notes`、`activity_sessions`、`quick_captures`、`ai_results` 相关。

### 4.2 审计发现（重要）

1. **日期键不可信。** 实测 `daily_records` 共 24 行，但 `date` 长度分布为：
   - 长度 0：9 行
   - 长度 1：4 行
   - 长度 3：2 行
   - 长度 4：4 行
   - 长度 5：4 行
   - 长度 10（标准 `yyyy-MM-dd`）：仅 1 行
   
   `mood_scores`、`exercise_days` 也各只有 1 行且 date 为空。
   说明当前 SQLite 是**早期/损坏的派生存储**，`daily_records` 这类数据**不可作为事实层**。
   该库属于“可重建的派生数据”，不是用户手写内容，但必须在上手前先确认来源后再处理。

2. **敏感明细以明文存在 SQLite。** `chrome_visits.url`、`activity_sessions.window_title`、`daily_records.mixed_overview`、`ai_results.answer` 都是明文。

3. **数据有多处副本。** 实时片段同时写在：
   - 加密 per-day `.activity` 文件；
   - SQLite `activity_sessions`；
   - 内存 `ActivityStore.sessions`。
   三处来源不同步时会出现“看起来一致但实际对不上”。

### 4.3 其他本地存储

| 存储 | 位置 | 是否加密 |
|---|---|---|
| 日记修改/快记/河流信/保存查询/整理 | `journal.state` | AES-GCM |
| 每日采集快照 | `Ingestion/daily-capture.bin` | AES-GCM |
| 旧采集快照（迁移用） | `Ingestion/health-snapshot.bin` | AES-GCM |
| 实时足迹 | `Activity/*.activity` | AES-GCM |
| API Key | `Keys/api-keys.bin` | AES-GCM（另有钥匙串迁移） |
| 构建期数据 | `data/raw.json`、`data/data.json` | 明文（gitignore） |
| 内置只读快照 | `Sources/.../Resources/data.json` | 明文（gitignore） |

> 结论：加密得到了重视，但敏感性与“是否进备份/是否可重建”没有统一建模。

---

## 5. Collectors（采集器）

现有采集逻辑：

| 采集器 | 事实来源 | 写到哪 | 评价 |
|---|---|---|---|
| 前台应用/窗口活动 | `NSWorkspace` 通知 | `ActivityStore` → 加密 `.activity` 文件 → SQLite 副本 | 事件驱动，符合方向；但逻辑在 Store 内部 |
| 窗口标题 | 辅助功能（AX） | 写入 ActivitySession | 有开关，有隐私保护（无痕/受保护窗口） |
| 睡眠/锁屏/唤醒 | `NSWorkspace` 通知 | 关闭/重开活动片段 | 事件驱动 |
| iOS 评分/睡眠/运动/快记 | iCloud `river-diary-user-data.json` | SQLite + `daily-capture.bin` + 内存合并 | 清洗逻辑在 `DataIngestionStore` 内 |
| Chrome 历史 | 直接读 Chrome History SQLite（只读副本） | SQLite `chrome_visits` + DailyCaptureRecord | 有专门 Reader；敏感 |
| Apple Notes | 直接读 NoteStore.sqlite | SQLite `daily_notes` + DailyCaptureRecord | 有专门 Reader；敏感 |
| 屏幕时长 | 来自 ActivityStore 实时聚合 | DailyCaptureRecord | 依赖实时片段质量 |

### 关键架构问题

- 采集职责**没有与业务逻辑分离**。一个 Store 同时负责采集、持久化、融合统计、调度 AI。
- Chrome / Notes 采集是“直接读第三方数据库”，涉及全盘访问/隐私信任，必须作为显式隐私边界管理。
- “Collector → RawEvent Store” 的边界不存在：采集结果直接进入汇总模型或 UI 可见的内存状态。

---

## 6. AI Pipeline

现状（真实，非目标）：

- 配置：`AIAssistantStore` 支持 12 种 OpenAI 兼容 provider（远程 + Ollama/LM Studio 本地）。
- 凭证：API Key 用加密文件存，旧钥匙串一次性迁移。
- 请求：仅此一个文件发网络（`URLSession`）。
- 上下文构建：`makeContext` / `analysisFactSheet` 在本地聚合 `FusedRangeStats + DiaryEntry + captures` 后序列化为 JSON 发送。
- 任务：`AITask` 定义 12 类（每日总结、足迹问答、记忆搜索、情绪河流、快记归纳、六件套分析…）。
- 归档：结果写入 SQLite `ai_results`，`DBAIResult` 只有 `resultKey/start/end/answer/sourceSummary`，**没有逐条 evidence id 清单**。
- 启动门槛：`RootView` 在未完成模型连接验证前显示 `AIRequiredSetupView` 且不可跳过；README 也写明“非 AI 分析模式已移除”。

### 架构问题

1. **没有 AI Boundary 层对象。** 谁有资格把哪些字段发给大模型，全藏在 1,400 行 Store 里。
2. **证据链条是叙述性的。** `sourceSummary` 是字符串，AI 答案中的日期由 `AISearchDateReferenceParser` 事后从文本反推，没有结构化证据 ID。
3. **AI 输出可以进入用户日记草稿**（`AIDraft` / 追加草稿），这会污染“手写日记 = 记忆原文字”这一层。后续 AI 上下文又把这些文字当依据，形成循环。
4. 自动分析在采集后定时触发，失败会重试；但“失败重试”与“已生成”状态只有 `lastAutomaticAnalysisDate` 等少量状态，没有健壮的作业表。

---

## 7. UI

- 主界面：`RootView` + 侧栏，五个流向（今天、时间、记忆、洞察、设置），另有菜单栏快记。
- 独立视图约 30 个文件、约 7,700 行。`AIAnalysisView` 687 行、`DataExplorerView` 848 行、`PrivacyView` 800 行、`DayTimelineView` 629 行、`RhythmView` 602 行是较大的视图。
- UI 直接依赖 4 个 `ObservableObject`（Store / Activity / AI / Ingestion），`DataExplorerView` 还直接访问 `AppDatabase.shared`。
- 视觉体系（`Theme.swift`、`SignalStyle.swift`、素材卡）已有较统一的设计语言。

### UI 问题

- 视图与 Store 强耦合，但没有严重“UI 创造 RawEvent”，主要风险是**读路径太散**：同一日期同一数据，可能经由 DiaryStore 合并、ActivityFusionEngine、AppDatabase、encrypted state 四条不同路径读取。
- “强制 AI 连接才能进主界面”与“本地优先、无 AI 也可用”的产品叙述冲突（README 现在坦白说是“必须填 Key”）。
- 部分页面是功能堆叠产物（DataExplorer 既有跨天查询又有数据库页又有导出），不适合作为长期结构。

---

## 8. Legacy Components（历史组件，先标记不删除）

| 组件 | 状态建议 | 备注 |
|---|---|---|
| Web 端 `src/`、`dist/`、`index.html` | ARCHIVE（仓库保留，不再参与 macOS 生命周期） | 历史三端遗产；数据快照是 macOS 只读素材之一 |
| Python 管道 `pipeline/` | ARCHIVE（只读消费产物） | macOS 未来应改从自己的事实存储读取，不再依赖构建期页面产物 |
| iOS 工程 | ARCHIVE（暂停） | 保留代码，不进 macOS 依赖 |
| `data/raw.json`、`data/data.json` | ARCHIVE（只读旧数据） | 手写日记原文在 raw.json，属于用户真实文字，只能迁移不能删除 |
| `Resources/data.json`（打包进 macOS） | REPLACE（改为只读示例或删除） | 这是 Web 管道的产物，不应继续作为 macOS 唯一数据源 |
| `hermes_logs` / “Hermes” 文案 | DELETE（确认无新代码引用后） | 旧采集脚本时代的痕迹 |
| `DesignArchive/HomeView.swift.disabled` | ARCHIVE 或 DELETE | 明显死文件 |
| `activity.state`（磁盘旧状态） | DELETE（先确认 DiaryStore 不再读取） | 遗留文件 |
| `Ingestion/health-snapshot.bin` 读取路径 | REFACTOR（旧快照迁移逻辑保留到修复期） | 代码里仍有 `legacyDataURL` 迁移路径 |

---

## 9. Dead Code

候选（未逐一删除，需在对应小步确认依赖）：
- `DesignArchive/HomeView.swift.disabled`
- `SignalStyle` 中 `hermes` 映射分支
- `AIKeychain` 的旧账号迁移路径（有旧安装才需要；修复期可收敛）
- `DiaryStore` 的 `legacyStateURL` 迁移路径
- `DataIngestionStore` 的 `legacyDataURL`（`health-snapshot.bin`）
- 备份目录 `backups/` 内容不属于代码，但不应被程序读取

---

## 10. Duplicate Code / Duplicate Models

| 重复项 | 位置 | 危害 |
|---|---|---|
| 日期格式化 `yyyy-MM-dd` | `DiaryEntry.dateFormatter`、`DatabaseTime`、`TimelineSegment`、`AISearchDateReferenceParser`、Windows… | 到处手写，容易不一致 |
| 屏幕时长/用时格式化 | `ActivityFormatter`、`DailyCaptureRecord.summary`、`LocalReview` 等 | 多数是显示差异，可统一 |
| “今天是哪天/上周是哪周”语义 | `MemorySearchEngine`、`ActivityQuestionEngine`、`DatationParser`（iOS？） | 同一自然语言日期解析写了两套 |
| 模型重复 | `DBMoodScore` vs `IngestedSleepNight` vs `DailyCaptureRecord` vs `DBDailyRecord` | 同一健康/评分数据有 4 个形状 |
| 活动会话 | `DBActivitySession`、`ActivitySession`、`DBQuickCapture` vs `QuickCapture` | 一层 JSON / 一层 DB，字段几乎一样 |
| 加密 Key 存储 | `StateEncryption` 与 `AISecureKeyStore` | 两套加密文件机制 |
| 分析/汇总 | `ActivityFusionEngine`（Day/Range）、`LocalReview`、`MoodInsight`、`ActivityInsightEngine` | 四套统计实现有重叠 |

---

## 11. Privacy Risks

1. **Chrome 历史直读**：把全量 URL + 标题（当日最多 1000 条）写入 SQLite 明文。属于最高敏感级别。
2. **Apple Notes 直读**：读取 Apple Notes 的标题（`ZTITLE1`）与修改时间并持久化。
3. **SQLite 明文**：`chrome_visits`、`daily_notes`、`activity_sessions.window_title`、`ai_results` 明文存储；虽然文件在应用目录，但没有像 `journal.state` 那样加密。
4. **AI 外发**：仅 `AIAssistantStore` 有网络；窗口标题默认不发送（`includeTitles` 开关），但发送时会把 app/时间/分类/站点/健康聚合发给第三方。当前 UI 无逐字段细粒度白名单。
5. **内置资源快照**：`Resources/data.json` 内联了用户日记/浏览站点/性（gitignore，但已打进 `.app` 会随产物分发）。
6. **权限使用不透明**：读取 Chrome/Notes 可能需要“完全磁盘访问”，但 UI 只在内容不在时静默返回 `[]`，用户不会知道为什么没数据。
7. **删除路径混乱**：`pruneRetention` 会直接 `DELETE` SQLite；`clearActivity` 会删加密活动文件；`clearLocalJournal` 会删 `journal.state`。三者语义不同且分散，容易误清。

---

## 12. Architecture Problems（按严重度排序，Evidence 优先）

1. **缺少事实层。**
   `ActivitySession` 同时充当“机器观察（RawEvent）”和“整理后的活动（Activity）”；`DailyCaptureRecord` 同时充当采集记录和每日聚合；没有不可变 RawEvent、没有事件 ID、没有 `evidence_ids` 引用。
   后果：无法回答“这段判断到底来自哪几条证据”。

2. **Episode 没有持久化与溯源。**
   `ActivityTimelineEngine` / `TimelineSegmentEngine` 是运行时派生，按 app 名/时长临时合并；
   `TimelineAnnotation` 用字符串 key 关联，没有 Episode 表与证据引用。

3. **Memory 本质是“全文搜索 + AI 摘要”，不是记忆层。**
   `MemoryArchive` 只是按天归档，`MemorySearch` 只是本地关键词匹配，
   AI “记忆搜索”是无约束聊天式搜索，没有结构化 Memory 对象与 provenance。

4. **God Object。** 4 个巨型 Store 混合了采集、持久化、统计、调度、备份、网络、格式化。

5. **数据库不可信。** SQLite 的日期键实测大量空/短格式，当前只应视为可重建派生层。

6. **双向污染风险。**
   - UI 不写 RawEvent（好）；
   - 但 AI 输出会追加进用户日记草稿（AI → 记忆文字层）；
   - `DataIngestionStore` 同时写 SQLite、加密快照、内存合并状态，多光是程序内部状态就互相覆盖。

7. **多个真相源。** `data.json` / `journal.state` / `.activity` 文件 / SQLite / `daily-capture.bin` 并存，
   同一事实不同副本靠“指纹+缓存”缓解，而非统一存储。

8. **强制 AI 入会。** 产品想让“无 AI 也能用”，实际 `RootView` 把模型连接验证做成硬门槛；
   这是产品与架构的明显不一致。

9. **命名/抽象过度。** 大量 `Engine`（Fusion/Confidence/Insight/Timeline/Segment/Chat/Question…）彼此重叠，
   部分只有一处实现却以抽象命名；“Activity”一词被用在套娃词汇里造成理解困难。

---

## 13. Build / Tests（本次验证，只读审计后）

- `swift build --disable-sandbox`（项目指定 Xcode-beta 工具链）：通过。
- `swift test --disable-sandbox`：**80 项通过，0 失败**。
  - 覆盖：活动融合、生命周期、时间线、可见搜索、模型、情绪洞察、河流信、时间线整理、工作区重构、逻辑特性。
  - 缺口：`AppDatabase` SQL 迁移、加密/解密、AI 请求失败、Chrome/Notes 解析、DB 保留期删除 均无自动化测试。
- Python/Web 测试本次未重跑（避免触碰生成产物）；文档记录最后一次 13 项通过、JS 语法通过。
- iOS/Web 构建未重跑（已不属于本次 scope）。

---

## 14. 结论与推荐排序

1. 从 macOS 单一端开始，冻结 Web/iOS/管道为“ARCHIVE 只读遗产”。
2. 先建**不可变 RawEvent 事实表**与统一的 SQLite Store，把旧 DB 视为可重建派生层。
3. 再把实时采集拆成独立 Collector，统一写 RawEvent Store。
4. 再建 Activity（确定性合并）、Episode（带证据 ID）、Memory（带 provenance）。
5. AI 只允许读取物化视图并写入带证据来源的分析归档，**不允许写记忆原文**。
6. 最后重构 App Shell/Today/Memory/Ask，删除确认无用的 Legacy。

> 以上排序与 `RIVER_REFACTOR_PLAN.md` 一致。
