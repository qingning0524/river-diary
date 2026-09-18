# RIVER_DATA_FLOW — 当前真实数据流（不是目标图）

> 只读审计产物，日期：2026-09-19。
> 本文件描述今天代码里**实际发生**的数据流，判断依据是源码路径 + 本地存储实测，不写“我们希望它是什么”。

---

## 总览（一张图）

```
   [iOS 应用]         [macOS 系统]            [Chrome/Notes]        [构建期脚本]
      │   健康/评分/快记     │ 前台应用/睡眠/唤醒        │ 直接读数据库          │ 生成 data.json
      ▼                     ▼                        ▼                     ▼
  iCloud JSON  ◄──────┐   NSWorkspace 通知      CSV?→SQLite读取          data/raw.json
      │               │       │                       │                       │
      ▼               │       ▼                       │                       │
 DataIngestionStore   │  ActivityStore              DataIngestionStore        │
      │               │   (sessions)                 │                        │
      │               │       │ 加密 .activity 文件   │                        │
      │               │       │                      ▼                        ▼
      │               │       └──────────► SQLite activity_sessions      DiaryStore
      │               │                                          (读取 data.json)
      ▼               ▼                                   │            │
  SQLite daily_records ◄── daily-capture.bin ◄────────────┘            │
      │               │                                   │            │
      ▲               │                                   │            ▼
      │               └─────────► ActivityFusionEngine ◄───┤      journal.state(加密)
   AIAssistantStore ◄────── 范围统计 / 日记 / 快记 / 活动 ◄┘            │
      │                                                              │
      ▼                                                              ▼
  URLSession → 远程/本地大模型                                          UI
      │                                                               ▲
      ▼                                                               │
  SQLite ai_results（AI 留档）───────────────────────────────────┘
```

说明：上面只是一次近似，真正的数据副本比线图更多（见第 7 节“副本清单”）。

---

## 1. 数据从哪来

### 1.1 iOS → iCloud（`river-diary-user-data.json`）
- 来源：iOS 端 `DiaryStore` + `HealthKitStore` + `ScreenTimeStore` + 本地评分。
- 落点：`~/Library/Mobile Documents/com~apple~CloudDocs/河流日记/river-diary-user-data.json`。
- 形状：`moodScores / sleepNights / exerciseDays / quickNotes`。

### 1.2 macOS 系统事件（实时足迹）
- 来源：`NSWorkspace` 的 `didActivateApplication`、`didDeactivate`、`didTerminate`、`willSleep`、`didWake`、`sessionDidBecomeActive`/`ResignActive`。
- 产物：app 名 + bundleID + 可选窗口标题（AX）+ 分类 + start/end 的 `ActivitySession`。
- 分类：`ActivityClassifier` 用关键词启发式（工作/学习/创作/沟通/娱乐/浏览/系统/其他）。

### 1.3 Chrome 历史（每日一次）
- `ChromeHistoryReader` 把 Chrome `History` 复制到临时文件后只读查询当天 `visits + urls`（上限 1000 条）。
- 结果：`[ChromeVisit]`（url、title、visitedAt、visitCount、domain）。

### 1.4 Apple Notes（每日一次）
- `AppleNotesReader` 直接只读查询 `NoteStore.sqlite` 当天修改过的 `ZICCLOUDSYNCINGOBJECT` 标题。
- 结果：`[DailyNoteEntry]`（title、modifiedAt）。

### 1.5 构建期数据快照
- `pipeline/` 把 `data/raw.json` 清洗成 `data/data.json` 并生成 Web 单文件；
- 同时复制一份进 macOS `Sources/RiverDiaryMac/Resources/data.json`（作为内置只读快照）。

---

## 2. 谁把数据写到哪里

### 2.1 ActivityStore（`ActivityStore.swift`）
- 接收系统事件，生成 `ActivitySession`。
- 应用切换/睡眠/锁屏/退出时才 `persist`：
  - 把当天全部片段按天加密写入 `~/Library/Application Support/RiverDiaryMac/Activity/YYYY-MM-DD.activity`。
  - 内存 `sessions` 保留最近 365 天。
- 注意：`ActivityStore` 自己还有暂停调度、屏幕时长快照、融合统计、备份/恢复、清除等业务。

### 2.2 DataIngestionStore（`DataIngestionStore.swift`）
- 每分钟 Timer 检查是否到了采集时刻（默认 22:30）。
- 采集时顺序：
  1. 读 iOS JSON → 哈希去重；
  2. 清洗 iOS 数据；
  3. `AppDatabase.saveIOSHistory()`（历史日）写入 SQLite；
  4. 读 Chrome、Notes（各受开关控制）；
  5. 从 `ActivityStore` 取当天 `ScreenTimeSnapshot`；
  6. 组装 `DailyCaptureRecord`；
  7. `persist()` 写加密 `Ingestion/daily-capture.bin`；
  8. `saveToDatabase()` 写 SQLite `daily_records` 并把活动片段再写进 SQLite `activity_sessions`；
  9. `pruneRetention()` 删除旧 SQLite 数据；
  10. 可选 `exportDailyRecord()` 导出 `data/ios-user-data.json` 到项目；
  11. `applyToStore()` 把健康/评分/快记合并进 DiaryStore；
  12. 可选触发 `runAutomaticDailyAnalysis()`（AI）。

> DataIngestionStore 是**采集器 + 清洗器 + 数据库写入器 + 调度器 + AI 触发器**。

### 2.3 DiaryStore（`DiaryStore.swift`）
- 启动读取 `Resources/data.json` 或外部连接的 `data.json`（`loadExternalOrBundledSnapshot`）。
- 合并：把 `ingestedHealth`/`ingestedScores`/`quickCaptures` 按日期并入 `DiaryEntry`。
- 用户写日记/快记/河流信/保存查询/时间线整理 → 写加密 `journal.state`（AES-GCM，`UserState`）。
- 外部 `data.json` 变更 → `DispatchSource` 监听 → 重新合并。
- 用户显式删除/分享/清空只影响 `journal.state`，不删除 `data.json` 原文。

### 2.4 AppDatabase（`AppDatabase.swift` + HistoricalImport）
- 只被三处用到：
  1. `DataIngestionStore`（写入派生采集）；
  2. `AIAssistantStore`（保存/读取 `ai_results`）；
  3. `Views/DataExplorerView`（跨天查询，UI 直接读 DB）。
- 没有独立的 Repository/迁移层，SQL 直接散在函数内。

### 2.5 AIAssistantStore（`AIAssistantStore.swift`）
- 请求前：读 DiaryStore.entries、quickCaptures、ActivityStore 的 `FusedRangeStats`/sessions。
- 组装 `AIAnalysisContext` JSON（本地聚合数值 + app/窗口标题白名单开关）。
- 调 `URLSession` POST `/chat/completions`。
- 成功后：
  - 结果按 `AITask + 日期范围` 存 `resultKey` → SQLite `ai_results`；
  - 部分结果会被格式化后追加到用户日记草稿（`AIDraft`）。

---

## 3. AI 在哪里介入（现状）

介入点有 12 个 `AITask`：
- `dailyOverview`、`footprintQuestion`、`insightReading`、`memorySearch`、`riverReading`、`noteThemes`
- `analysisDaily / Mood / Focus / Health / Weekly / Action`

上下文构造规则：
- 永不发送 `journal.state` 原文之外的用户隐私字段（没有明确的落库清单）；
- 窗口标题只有 `includeTitles` 为 true 才发送；
- 每日采集后自动触发 `analysisDaily`，当日不重复；失败会在下次采集或启动重试。

**没有**：发送前的逐证据白名单、证据 ID、AI 回答的机器可读溯源。

---

## 4. UI 从哪里读（现状）

| UI 页面 | 主要读取对象 |
|---|---|
| Today / 日记 | `DiaryStore`（合并后 `DiaryData` 内存模型） |
| 时间线 | `ActivityStore`（实时片段）+ `DiaryStore`（快记/整理注释）+ `ActivityFusionEngine`（范围） |
| 记忆 | `DiaryStore` + `MemoryArchive` / `MemorySearch`（本地字符串搜索），AI 可选 |
| 洞察 | `AIAssistantStore` + `ActivityStore`（统计）+ `DiaryStore` |
| 数据分析 | `AppDatabase.shared`（直接跨天查询）+ `DiaryStore` |
| 设置 | 四个 Store、`UserDefaults`、`AppDatabase` |
| 菜单栏快记 | `DiaryStore.addQuickCapture` |

---

## 5. 现有“分层感”实际在哪

- **RawEvent 近似层**：`ActivitySession`（实时）、`ChromeVisit`、`DailyNoteEntry`、`IngestedQuickNote`、`iOS Sensor 数据`。
  但**没有统一结构、没有不可变 ID、没有来源哈希**。
- **Activity 近似层**：`ActivityFusionEngine.dayStats/rangeStats`、`ActivityClassifier`。
  用时序/时长计算得出，具备确定性，但没有持久化。
- **Episode 近似层**：`ActivityTimelineEngine`（相邻同类合并）、`TimelineSegmentEngine`（时段切分）、`TimelineAnnotation`（人工命名）。
  全部运行时派生，不落库。人工注释用字符串 key 关联，不引用证据 ID。
- **Memory 近似层**：`MemoryArchive`（按天归档描述）、`MemorySearch`（关键词）、`MonthlyLetter`（人工可编辑的信）、`LocalReview`（统计）、`ai_results`（AI 文本）。
  没有跨时间 Memory 对象、没有置信度、没有 provenance。
- **Context 近似层**：`AIAnalysisContext`（发给模型的结构化 JSON）、`AdvancedDataView` 的跨天查询。
  只在请求时生成，不入库。

---

## 6. 结论：真正的数据管家是谁

`DiaryStore` 是 macOS 的“印象层”：所有 UI 最终都绕到它这里的合并后 `DiaryData`。
`ActivityStore` 是“实时活动层”的主人。
`DataIngestionStore` 是“外部/管道数据”的搬运工。
`AppDatabase` 是“派生 + AI 归档”仓库。
`journal.state` 是“用户亲手写的东西”的唯一真源。

问题在于：
- 这些“层”之间没有统一契约；
- 同一事实经常同时在好几个地方有副本；
- 没有任何一层能回答“这条记忆的依据是哪几条 RawEvent”。

---

## 7. 副本清单（同一事实的多处存档）

| 事实 | 副本位置 |
|---|---|
| 今日活动片段 | `.activity` 加密文件 / 内存 `sessions` / SQLite `activity_sessions` / `FusedDayStats.liveSessions` |
| 单日健康/评分 | `daily-capture.bin` / SQLite `daily_records` / DiaryStore 内存 `ingestedHealth+ingestedScores` / `data.json` 里的 `ios_health` |
| 快记 | SQLite `quick_captures` / DieryStore `quickCaptures` / `journal.state` |
| 窗口标题 | `ActivitySession.windowTitle`（首付） / SQLite `activity_sessions.window_title` |
| AI 结果 | SQLite `ai_results` / 部分追加进 `journal.state` 草稿 |

集中化（单一事实存储）是 V2 架构的第一工程目标。
