# RIVER_V2_ARCHITECTURE — macOS Personal Memory OS 目标架构

> 只读审计产物，日期：2026-09-19。
> 这份文档描述“我们要改成什么样”，与 `RIVER_DATA_FLOW.md`（现状）分开。

---

## 0. 设计原则（从现状问题反推）

1. 单一事实存储：`RawEvent → Activity → Episode → Memory → Context` 用**一套 SQLite**承载，不再多份 JSON 文件当真相。
2. 禁止反向污染：UI 不写 RawEvent，AI 不写 Episode/Memory，Episode/Memory 永远带着 `evidence_ids`。
3. 可理解 > 抽象：去掉套娃 Store / Engine；一个类一个职责。
4. 无 AI 可用：任何 Open/AI 页面都必须能在“无模型连接、无网络”时用本地确定性数据工作。
5. 用户文字与自动分析分离：手写日记是“记忆原文”，永远不被 AI 自动改写。
6. 事件驱动优先：采集走系统事件，不靠高频轮询；唯一允许的 Timer 是“每天采集时刻检查”。

---

## 1. 目标数据流（北星）

```
macOS Signals (NSWorkspace / Chrome / Notes / iOS export / Health …)
        │  Collector（只采集）
        ▼
   RawEventStore ──► raw_events 表（不可变）
        │  Normalizer（确定性规则）
        ▼
   ActivityStore ──► activities 表（去重/合并/idle 过滤）
        │  EpisodeEngine（确定性分组 + 人工命名）
        ▼
   EpisodeStore ──► episodes 表（title/summary/confidence/evidence_ids）
        │  MemoryEngine（跨时间沉淀，Only Episodes）
        ▼
   MemoryStore ──► memories 表（provenance 指向 episodes）
        │  ContextBuilder（提供 UI/Ask 的可解释上下文）
        ▼
   UI / Today / Memory / Ask / Inspector
```

**规则**
- `raw_events` 是 Evidence；创建后只允许追加和按保留策略删除，不允许 SNOW。
- `activities`、`episodes` 是可重建的派生数据；删除后可从 `raw_events` 重算。
- `memories` 只能从 episodes 生成，并记录 `source_episode_ids`。
- AI 只读 **Context（物化视图）**，写 `analysis_runs`（AI 分析归档）；从不写事实层。
- Ask 只回答有证据支撑的问题；没有证据时回答“不知道”。

---

## 2. Domain Models（目标）

```swift
struct RawEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var timestamp: Date
    var source: RawEventSource          // systemApp, chrome, notes, iosHealth, ...
    var kind: RawEventKind              // appForeground, screenLock, windowTitle, urlVisit, ...
    var payload: RawEventPayload        // 结构化、可 JSON 化（不塞文本描述）
    var sourceHash: String              // 去重用
}

struct Activity: Identifiable {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var groupKey: String                // 决定它属于哪一类的确定性逻辑键
    var primaryApp: String?
    var category: ActivityCategory
    var evidenceIDs: [UUID]             // -> raw_events
}

struct Episode: Identifiable {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var title: String                   // 人工可改
    var summary: String                 // 确定性摘要，可人工改
    var category: EpisodeCategory
    var confidence: Int                 // 0..100
    var confidenceFactors: [Factor]
    var activityIDs: [UUID]             // -> activities
    var evidenceIDs: [UUID]             // 汇总的 evidence，去重后的 superset
}

struct Memory: Identifiable {
    var id: UUID
    var title: String
    var body: String
    var kind: MemoryKind                // 长期事实 / 习惯 / 项目轨迹 / 人际
    var confidence: Int
    var sourceEpisodeIDs: [UUID]        // -> episodes (provenance)
    var createdAt: Date
    var lastConfirmedAt: Date?
    var isUserConfirmed: Bool           // 用户可能 “确认/修正” 记忆
}

struct AnalysisRun: Identifiable {      // AI 边界
    var id: UUID
    var task: AITask
    var inputContextReference: UUID      // -> context_snapshots
    var outputText: String
    var evidenceIDs: [UUID]
    var model: String
    var createdAt: Date
}
```

禁止引入的抽象：
- 不建 `BaseRepository<TProtocol>`、不建 `IManager`、不建跨端 `Platform` 服务。
- 命名直接描述对象（`episodeRepository.store(episode)` 而不是 `dataManager.theThing()`）。

---

## 3. Storage

目标：**一个 SQLite 文件**，`~/Library/Application Support/RiverDiaryMac/river-v2.db`。

核心表（建议，最终以迁移设计为准）：

| 表 | 说明 | 是否可重建 |
|---|---|---|
| `raw_events` | Evidence：id, timestamp, source, kind, payload_json, hash | 是（来自采集），但 AI 与用户观察都以它为准 |
| `activities` | Activity：id, start, end, group_key, category, evidence_ids | 是（从 raw_events 重算） |
| `episodes` | Episode：id, start, end, title, summary, confidence_factors, activity_ids, evidence_ids | 是（从 activities 重算）；手写 title/summary 不可覆盖 |
| `episode_annotations` | 用户对 episode 的手工标题/补充/收藏/删除标记 | 否（用户文字） |
| `memories` | Memory：跨时间记忆 + provenance | 部分（provenance 系导航，文本为 AI 推导+用户确认） |
| `memory_confirmations` | 用户确认/修正记录 | 否（用户行为） |
| `context_snapshots` | 每次 Context 构建时的物化快照 + 引用 evidence_ids | 可重建（但保留审计价值） |
| `analysis_runs` | AI 分析归档（model / prompt hash / output / evidence） | 否（留档） |
| `user_prefs` / `user_state` | 设置与用户本地状态 | 否（用户本地） |
| `collections`（可选） | 引用类型数据的键值表，避免硬编码状态机 | 否 |

设计约束：
- 所有时间以 ISO `yyyy-MM-dd'T'HH:mm:ssZ` 存；日期查询用 UTC 语义定义清晰。
- 用户手写内容放进独立表 + 单独加密策略，不与机器观察混在一条宽表。
- 敏感列（Chrome URL、窗口标题、Notes 标题）要么加密列，要么进安全值表并绑定权限。
- 所有派生表写入前先算 hash（确定性），供审计与去重。
- 分布迁移时要能 `DROP → 重建派生表` 而**不影响 raw_events 与用户文字**。

---

## 4. AI Boundary

```
   ContextBuilder
        │  reads raw_events/activities/episodes（按策略裁剪）
        ▼
   ContextSnapshot (物化，不入 model 原文)
        │
        ▼
   AIClient (只读，无权写事实层)
        │
        ▼
   analysis_runs (AI 输出 + evidence_ids + model)
```

规则：
- AI **只能读 ContextSnapshot**，不直接读 `raw_events` 全量或用户原文。
- 发送前有一条“字段白名单”：哪些 app 名、站点、聚合数、窗口标题可发送，逐项可关闭。
- AI 输出**不能**被自动写回 `episodes.title/summary` 或 `memories.body`；
  只能作为 `analysis_runs`，若用户点击“采用”才变成 Episode/Memory 的补丁（并记录来源 AI + 用户确认）。
- 无模型时：Ask 走 `localIndex`（关键词 + 日期解析 + Episode 聚合）+ `analysis_runs` 历史，明确回答“本机可以给出这些证据”。

---

## 5. Privacy Boundary

1. `Collector` 只有两类权限：
   - 事件订阅（NSWorkspace / 时钟事件，无需全盘访问）；
   - 用户显式授权的源（Chrome/Notes/iCloud），每个源有独立开关与独立加密密钥域。
2. 所有敏感数据在入库时分类：
   - `public-safe`（app 名、类别、时长、聚合数）
   - `sensitive`（窗口标题、URL、Notes 标题、AI 分析正文）
   - `user-content`（日记、快记、注释、河流信）
   `sensitive` 与 `user-content` 单独加密，绝不进 RawEvent 的基础明文列。
3. UI 只按“数据源健康面板”显示采集状态，不输出原始 SQL/日志。
4. 导出/备份区分：全量备份包含所有层；轻量导出只含用户内容或聚合。
5. 删除永远分层：删除机器观察 ≠ 删除用户文字 ≠ 删除 AI 归档，模型在 UI 和 API 上都分开。

---

## 6. UI Architecture

```
App
 ├─ RootView (shell only：导航/锁/命令)
 ├─ Today          ← TodayStore(fact builder: 今天几个 episode)
 ├─ Timeline       ← TimelineStore → EpisodeReader
 ├─ Memory         ← MemoryReader (+ memorySearchService 本地)
 ├─ Ask            ← ContextView → askService (本地 or AI, 带证据列表)
 └─ Settings       ← SourceHealthPanel / PrivacyView / Backups
```

约束：
- View 不再直接访问 `AppDatabase`；统一经 `Store`。
- 一个 Store 默认对应一个聚合查询（Today/Timeline/Memory/Ask），不做跨域巨无霸。
- 无网/无模型状态是首等状态：UI 有 `unknown/low-confidence` 空态，而不是显示错误大卡。
- 视觉继续沿用现有 `Theme`/`SignalStyle`（不要为了“新架构”重画一张皮）。

---

## 7. 推荐目录（目标，供重构时落地）

```
Sources/RiverDiaryMac/
├── App/                  # 入口、Root、Shell
├── FactLayer/            # RawEvent / Activity   (采集+Normalizer)
├── EpisodeLayer/         # EpisodeEngine / EpisodeRepository / Annotations
├── MemoryLayer/          # MemoryEngine / MemoryRepository / Confirmations
├── AskLayer/             # ContextBuilder / LocalIndex / AskService / AIBoundary
├── Analysis/             # AITaskRunner / AIClient / AnalysisArchive
├── Storage/              # SQLite / Migration / Encryption / PrivacyClasses
├── Collectors/           # SystemApp/Chrome/Notes/iOSImport + SourceHealth
├── Privacy/              # PermissionStore / DataSourceHealth / Export
├── UI/                   # Today / Timeline / Memory / Ask / Settings / Inspector
├── Support/              # Theme, Formatters, Hash
└── Tests/

```

> 以上只是目标树；在重构计划里会以小步骤渐次出现，不制造空心目录。

---

## 8. Definition of Done（与 V2 验收一致）

- 用户整天使用 Mac，Today 能给出“开始/离开/主要做的事/哪些属于同一段”且能点进每条证据。
- 使用一周后 Memory 能形成真实长期记忆（从 Episode 沉淀）。
- Ask 能回答“我这周主要做了什么”，且答案可逐条追溯到 Episode/RawEvent；不知道就回答“不知道”。
- 断开网络、不连模型时，Today/Timeline/Memory/本地 Ask 依然可用。
- 每个阶段结束：`DATA IMPACT` 明确、`BUILD` 通过、`TESTS` 通过、可回滚。
