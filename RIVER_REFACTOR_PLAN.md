# RIVER_REFACTOR_PLAN — V2 重构小步计划

> 只读审计产物，日期：2026-09-19。
> 规定：每步核心 diff < 500 行（除非是删除代码）；每步可独立 Build / 测试 / Commit / 回滚；
> 数据库结构性变更必须先报告，绝不删除用户真实文字。

---

## 0. 阶段纪律

- 顺序执行，不小跳。
- 每完成一步：输出
  ```
  CHANGED / DELETED / WHY / DATA IMPACT / BUILD / TESTS / RISKS / NEXT
  ```
  然后 **STOP**，等待确认，不自动开始下一阶段。
- 每一步对应一个分支 `codex/v2-<step>`，可在 `git revert` 或切分支回滚。
- “删除”只允许删除可重建产物、明显死文件、无引用旧代码；任何删除先跑 `grep` 依赖检查。
- 用户真实数据（`data/raw.json` 内容、`journal.state` 内容、用户手写文字）在进程中只允许平移/导出，不缺省删除。

---

## 1. 阶段总览（对应任务书 Phase 1–12）

| Phase | 标题 | 对应步骤 |
|---|---|---|
| — | 审计产物（本文档 + AUDIT + DATA_FLOW + CODE_MAP + V2_ARCHITECTURE） | 已完成 |
| Phase 1 | 清理命名与明显死代码 | Step 1–4 |
| Phase 2 | 建立干净 Domain Layer | Step 5 |
| Phase 3 | 整理数据库 | Step 6–7 |
| Phase 4 | 整理 Collectors | Step 8–9 |
| Phase 5 | RawEvent → Activity | Step 10–12 |
| Phase 6 | Activity → Episode | Step 13–14 |
| Phase 7 | Episode → Memory | Step 15–16 |
| Phase 8 | 重构 App Shell | Step 17 |
| Phase 9 | 重构 Today | Step 18 |
| Phase 10 | 建立 Memory | Step 19 |
| Phase 11 | 建立 Ask | Step 20 |
| Phase 12 | 删除确认无用的 Legacy | Step 21 |

---

## 2. Step 明细

### Step 1 — 代码冻结声明与文档落地（只读，非代码）
- 目标：把 Web/iOS/Pipeline 正式标记 ARCHIVE，写入 `README`/`docs/`。
- diff：几乎 0（只改文档）。
- Build：文档不影响构建。Tests：不变。
- DATA IMPACT：无。
- Risk：无。
- 回滚：git 层面即可。

### Step 2 — 死文件与显式不可用代码（删除类）
- 目标：删除无引用的 `DesignArchive/HomeView.swift.disabled`、`hermes` 字符串残留、`activity.state` 与 `health-snapshot.bin` 迁移读取（若 `grep` 确认无引用）。
- 先跑：`grep -rn "HomeView\|activity.state\|health-snapshot\|hermes" Sources`。
- 约束：若 FileManager 仍引用旧路径，先改为“本拿到数据时静默跳过”，下一步再删函数。
- diff：预计 < 200 行删除。
- Tests：跑 80 项 Swift 测试。

### Step 3 — 命名清理（Rename-only）
- 目标：把套娃命名收敛为自解释名称，例如：
  - `ActivityTimelineEngine.build` → `episodeBuilder.build(for:)`
  - `DailyCaptureRecord` → `DailyIngestionSnapshot`（仅内部）
  - `ActivityFusionEngine` → `footprintStats.compute(...)`（内部纯函数）
- 规则：一次只改一个语义块；保持公开 API 兼容或同步改调用点；不建新抽象。
- diff：预计 < 400 行改（rename）。
- Tests：80 项 + 新增 2–3 个命名/依赖 grep 断言。

### Step 4 — 合并重复模型与日期工具（Refactor）
- 目标：统一日期格式化/自然语言日期解析到单一 `DateKey.swift`；把 `MemorySearchEngine` 与 `ActivityQuestionEngine` 的日期语义合并调用。
- 删除重复 DTO：`DBMoodScore` 等只在 DB 内部用，保留在 DB 层；`DailyCaptureRecord` 与 `Ingested*` 的重复形状先合并进一个“采集 DTO”。
- diff：预计 < 450 行。
- Tests：全部 Swift 测试 + 新增日期解析表位测试。

### Step 5 — 建立干净 Domain Layer（Phase 2）
- 目标：新增（不改旧行为）：
  ```
  Domain/RawEvent.swift        # 不可变，含 payload/sourceHash
  Domain/Activity.swift
  Domain/Episode.swift
  Domain/Memory.swift
  Domain/EvidenceRef.swift
  Domain/AnalysisRun.swift
  ```
- 先只定义纯 model + 测试，不替换任何旧系统数据路径。
- diff：约 300–500 行新文件。
- DATA IMPACT：无（新表未建，旧路径保持）。
- Tests：新增 10–15 个纯 model 测试。

### Step 6 — 新建 V2 数据库骨架（Phase 3）
- 目标：在 `AppDatabase` 旁边新增 `V2Store`（新文件 `river-v2.db`），建表：
  `raw_events / activities / episodes / memories / context_snapshots / analysis_runs / episode_annotations / memory_confirmations / user_prefs`。
- **只建表，不迁移旧数据，不删除旧库。**
- diff：约 400 行。
- DATA IMPACT：新增一个独立 DB 文件；旧库原样。
- Tests：新增 DB 建表/索引/关闭测试。

### Step 7 — 迁移策略报告（非代码）
- 目标：产出一份 `docs/RIVER_V2_MIGRATION.md`（写入该小步），列：
  - 旧库哪张表可重建、哪张用户数据需平移；
  - 迁移是否破坏性；
  - 保留期策略；
  - 回滚方案（保留旧库副本）。
- 未经你确认不做任何迁移执行。

### Step 8 — 拆分 ActivityStore 采集器（Phase 4）
- 目标：把 `ActivityStore` 的 NSWorkspace 监听+片段生成抽成 `Collectors/SystemAppCollector.swift`（只产出 `RawEvent`），`ActivityStore` 只保存/查询。
- 行为不变：暂停调度仍由 Store 控制；事件仍存 `.activity`（临时，后续迁 DB）。
- diff：约 350–450 行合理重构。
- Tests：新增 Collector 事件→RawEvent 单元测试（synthetic）。
- 注意：保持当前 UI 可用，不重写。

### Step 9 — 拆分 DataIngestionStore（Phase 4）
- 目标：把 iOS 清洗/Chrome/Notes 组装拆成 `Collectors/ExternalSourceCollector.swift`，把“写库/导出/AI 触发”留在 Scheduler。
- 不改变行为；先让 `captureDaily` 调用新 Collector。
- diff：约 400–500 行。
- Tests：新增 iOS payload 清洗/去重/异常校验测试、Chrome/Notes 解析测试。

### Step 10 — RawEvent 落库（Phase 5 第一部分）
- 目标：`SystemAppCollector` 与 `ExternalSourceCollector` 完成后，把每事件写入 `V2Store.raw_events`。
- 旧 `.activity` 仍写（兼容红线：不让用户数据消失），但新工厂只从 raw_events 重建。
- diff：约 300–400 行。
- DATA IMPACT：新增 RawEvent 表增长；只追加不 SNOW。
- Tests：RawEvent 持久化 + 去重 + 保留期删除。

### Step 11 — Activity（确定性合并）层（Phase 5 第二部分）
- 目标：新 `Normalizer` 从 raw_events 生成 `activities`（合并/去重/idle/噪声过滤）。
- 替换 `ActivityFusionEngine` 中“从 ActivitySession 算 dayStats”这一段的只读调用为可重放纯函数（不立刻改 UI）。
- diff：约 400–500 行。
- Tests：活动合并、idle 检测、跨天裁剪。

### Step 12 — 旧数据只读兼容
- 目标：让 Today/Timeline 读“Convenience 聚合”时优先 `activities`，没有则回退旧路径（临时双读取，证据已迁移则回退去掉）。
- diff：约 300 行。
- 完成时 `Phase 5` 达成：RawEvent → Activity。

### Step 13 — Episode Engine（Phase 6）
- 目标：把 `ActivityTimelineEngine`/`TimelineSegmentEngine` 收敛成 `EpisodeEngine`，产出带 `activityIDs + evidenceIDs + confidence` 的 Episode。
- 保留 `TimelineAnnotation` 并入 `episode_annotations`。
- diff：约 400–500 行（含删除旧 Engine 合并逻辑）。
- Tests：Episode 归组、confidence、证据映射。

### Step 14 — Episode 落库并接入 UI 读取
- 目标：Episode 写入 `episodes`；时间线改为读 Episode 而不是临时算。
- 仍保留 `.activity` 与旧时间线可读（兼容窗）。
- diff：约 350 行。
- 完成时 `Phase 6` 达成。

### Step 15 — Memory Engine（Phase 7 第一部分）
- 目标：从 episodes 沉淀 `memories`（确定性规则 + 可选项：用户确认）；每个 Memory 记录 `source_episode_ids`。
- 不调用 AI。
- diff：约 300–400 行。
- Tests：Memory provenance、未知/低置信度处理。

### Step 16 — AI 归档纳入边界（Phase 7 第二部分）
- 目标：AI 输出不再追加进用户日记草稿；改写进 `analysis_runs` 并带 evidence。
- 将相关 `AIDraft`/“追加草稿”调用点改为生成 `AnalysisRun`（临时：可在草稿区显示“来自 AI 的分析”，但不再把 AI 文本当作 UserState 覆盖写）。
- diff：约 400 行（重构 AIAssistantStore 的写入路径）。
- Tests：AI 不写 raw/不写 memory、失败不产生脏数据。

### Step 17 — 重构 App Shell（Phase 8）
- 目标：`RootView` 只留导航/锁/命令；AI 连接验证改为“可选择跳过”的本地模式。
- 删除“未连接模型不许进主界面”的硬性门禁。
- diff：约 350–450 行。
- Tests：无 AI 时今日/时间线/记忆可打开。

### Step 18 — 重构 Today（Phase 9）
- 目标：Today 从 `episodes/activities` 构建“今天开始/工作/主要事项/离开”，不使用 AI 编造。
- 移除 Today 里的“无证据推断”。
- diff：约 400 行视图 + 纯逻辑分离。
- Tests：Today 合成数据验收。完成 `Phase 9`。

### Step 19 — 建立 Memory 页面（Phase 10）
- 目标：把 `MemoryArchive` 升级为读 `memories` 表 + 手动确认/修正 UI；保留旧“按天归档”视图。
- diff：约 400–500 行。
- Tests：Memory provenance、用户修正、删除不影响 episodes。

### Step 20 — 建立 Ask（Phase 11）
- 目标：Ask 用 `ContextBuilder + localIndex + AnalysisRun 归档`；可选 AI 请求带回结构化证据，无结果时明确“不知道”。
- diff：约 500 行以内（尽量 <500）。
- Tests：Ask grounding（每个事实有 evidence 可回到 raw_event）。

### Step 21 — Legacy 清理（Phase 12）
- 目标：在确认 `raw_events/activities/episodes/memories` 已接管职责后，按序删除旧 `.activity` 写入、旧 `daily_records` 写入路径、旧 `data.json` 唯一数据源读取、旧 Web/iOS 引用。
- 每次删除一个子系统 + 跑全部测试 + 记录 `DATA IMPACT`。
- 完成时 `Phase 12` 达成。
- 删除前仍保留只读备份目录（不删除用户数据副本）。
- 预留：`query-queued`（暂无独立分支）。

---

## 3. 测试策略（贯穿全程）

- 建 Synthetic Dataset：`Tests/Fixtures/synthetic-events.json`（app 切换/睡眠/快记/跨天/噪声/开发会话）。
- 核心必测：
  - RawEvent 持久化与不可变
  - Activity 合并 / 去重 / idle 检测 / 跨天裁剪
  - Episode 分组与大量切换碎片
  - Episode → Memory provenance
  - AI 失败不落脏数据、不刷新、可重试
  - 数据库迁移（新库建/老库不动/回滚保留）
  - 删除派生数据的可重建性
  - 隐私排除（Chrome/Notes 关闭时不产生记录）
  - Ask grounding（“每到结论有证据”）
- 不用真实私人数据做唯一测试数据。

---

## 4. 验收门（Definition of Done V2）

- 用 Mac 一整天 → Today 能基本正确给出开始/工作/离开/同一段活动。
- 点击 Episode → 能看到 Evidence（RawEvent 列表）。
- 用一周 → Memory 能形成真实长期记忆且可追溯 Episode。
- Ask：“我这周主要做了什么？” → 有证据引用的回答；没有证据则说“不知道”。
- 每个 Phase 结束都符合第 0 节纪律：能 Build、能 Test、能 Commit、能回滚。

---

## 5. 风险登记（排序）

1. **Retention 删除**：机器观察按保留期删除可能误删未来需要重建 Memory 的证据 → 保留原始 RawEvent 的最长周期单独配置，默认 ≥ Memory 引用期。
2. **旧 DB 日期不可信**：迁移前不得让旧 `daily_records` 变成新事实来源。
3. **AI 文本误写日记**：Step 16 前先阻断，避免继续污染记忆原文。
4. **双读取兼容窗**：Step 12/14 的双读写容易不同步 → 每次只换“读取”或“写入”一端，不两端同时改。
5. **Xcode 工具链**：CI 必须固定用项目 Makefile 的 Xcode-beta 工具链，避免 CommandLineTools 的 SDK/编译器错配误报。
