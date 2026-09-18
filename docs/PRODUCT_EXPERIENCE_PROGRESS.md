# River macOS 产品体验升级 — 进度记录

更新：2026-09-19（codex/ui-redesign 分支）

## 本轮目标
基于上一轮 MemoryOS 重构后的 UI，补齐成熟 Mac 软件应有的体验：真实数据入口、操作反馈、状态覆盖、键盘与交互细节。不删减业务能力。

## 关键决定
- 延续 NavigationSplitView（Sidebar / Content / Inspector），不为统一布局强行改造成单一模板。
- 不删除原有业务能力；恢复的入口都走真实 Store/模型，不引入模拟数据。
- 搜索/筛选条件在页面内保持，可重置。
- 收藏证据仍按“活动片段”粒度（TimelineAnnotation），保持数据语义真实，不从 Memory 伪造收藏写入。

## 已完成
1. 共享组件：`Views/SharedUI.swift`
   - EmptyStateView（现状 + 下一步动作）
   - FilterChip / QuietSectionHeader / OverviewStat / StatusDot
2. Today（真实主页）
   - 顶部“已记录 / 快记 / 专注 / 继续工作”概览，全部来自真实 Store
   - 采集状态显示（正在采集/已采集/有问题）
   - “Continue”已保存查询快捷跳转 Ask
   - 键盘日期导航：⌘← / ⌘→；写一句 ⌘N
   - 空状态升级（今天记录中 / 无数据可操作）
3. Memory
   - 筛选：全部 / 有笔记 / 快记 / 收藏，条件可见可重置
   - 排序：最近 / 最早
   - 行内容更密：短日期、收藏星标、标签、日记/快记/标签来源计数
   - 右键菜单：打开这一天 / 复制预览；无结果可恢复
4. Ask
   - 查询由壳层持有（可从 Today“继续工作”直达）
   - 已保存查询快速入口、RECENT 历史、保存查询
   - 清除输入、Ask again、无证据空态
   - 结构化结果计数（天数/笔记/快记）与证据按钮
5. Inspector
   - 快记支持复制 / 删除（带确认）
6. Settings
   - 顶部“当前状态”：记录状态、采集状态+立即采集、AI 连接+配置
7. Shell
   - Escape 关闭 Inspector

## 未完成 / 明确限制
- 尚未为任何“待处理/批量”能力接入真正的多选或批量操作（现有数据模型无对应真实源）。
- 尚未覆盖“导入进行中”的分步骤进度条（现有 DataIngestionStore 仅暴露 isRunning / 状态文案）。
- Xcode 沙盒环境未运行 GUI，未能输出截图；当前验证为 swift build + 80 项测试通过。
- 旧页面（时间线/情绪河/节律/洞察/AI 搜索/随笔/高级数据）仍为 ARCHIVE 代码，未在本次删除。

## 验证结果
- swift build --disable-sandbox：通过
- swift test --disable-sandbox：80 项通过（0 失败）
- 提交：`feat: mature macOS product experience (...)`（6 文件，+802/-148）

## 追加：旧页面清理 + V2 数据层（2026-09-19 第二轮）

### 旧页面清理（Phase 12 起点）
- 删除 25 个无引用的旧页面/旧容器文件（AIAnalysis、AIRequiredSetup、AITaskCard、Activity、DataExplorer、DayTimeline、FlowViews、Insight、LocalReview、MemoryArchive、Memory、MonthlyLetterCard、MoodAreaChart、NavigationDateCard、Notes、Rhythm、River、Root、SavedQueryEditor、TimelineAnnotationEditor、TimelineJournalPanel、TimelineSegmentCard、TimelineWorkspaceHeader、TodayDateSelector、TodayView）。
- 保留：AIConnectionCard（Settings 用）、AppLockGate、PrivacyView、QuickCaptureView、NavigationModels、WorkspaceUtilities（测试依赖其 parsedDate）。
- 纯模型 LifeSegment / RiverLetter / Pearson 从 Rhythm 视图抽到 `Domain/LifeRhythm.swift`，测试继续通过，数据层不丢。
- 旧能力去向：月度信(RiverLetter)模型与 store.monthlyLetters 数据仍在；采集与健康概览由 Settings/PrivacyView 与 Today 采集态承接；搜索由 Memory/Ask 承接；AI 由 Settings→配置 AI 承接。旧页面入口不再存在（这是本次“完成旧页面”的语义）。
- 验收：swift build 通过；swift test 93 项通过。

### V2 数据层（Phase 2–3 完成）
- Domain 模型：RawEvent / Activity / Episode / Memory / AnalysisRun / EvidenceRef（纯 Codable+Hashable，带证据溯源辅助）。
- `Storage/V2Store.swift`：独立 `river-v2.db`，建 9 张表 + 索引；raw_events 追加式，clearDerivedData 只清可重建衍生表、保留证据。
- `docs/RIVER_V2_MIGRATION.md`：迁移策略（未执行，旧库不动）。
- 验证：新增 13 项测试，总计 93 项全部通过。
- 未做（下一步）：采集器写入 raw_events、Normalizer→Activity、EpisodeEngine、MemoryEngine、Ask grounding 接入 UI。
