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

## UI Review（MemoryOS macOS 深度重设计，2026-09-19 第三轮）

### 当前 UI 最明显的问题（11 条）
1. **页面标题过大、且用衬线大字**（Today 30pt / Ask 32pt / Settings 28pt editorial）——像消费级 App / AI 生成，不像 Mac 专业工具。
2. **彩色装饰性眉标**（"A PAGE OF YOUR LIFE / 记住那些值得记住的" amethyst monospaced）——纯视觉噪音，重复表达当前位置。
3. **Sidebar 仍是“大按钮+胶囊选中态+品牌贴片”**，每项有背景、行高 36、圆角 10——不是系统 Sidebar 的克制密度。
4. **Today 顶部是“四格 KPI 仪表盘”**（已记录/快记/专注/继续 4 个大图标统计）——SaaS Dashboard 味道，信息密度假高。
5. **Toolbar 基本只挂一个"写一句"**，搜索/筛选/Inspector 切换没有进 Toolbar，操作职责没真正落在桌面级 Toolbar 上。
6. **同一主操作重复**：Today 头部“写一句”+ Toolbar“写一句”+ 概览里的快记入口，权重重复。
7. **每页结构完全雷同**（大标题 + 卡片/列表容器），缺少面向任务的真实信息架构差异。
8. **Memory 列表信息密度低**：行间距大、来源计数不够清晰，没有真正的表格/快速扫描结构。
9. **Ask 居中大标题 + 居中输入**——ChatGPT 克隆感，大屏大量空白。
10. **自定义语义色 use（ink/secondaryInk/amethyst）在正文头部过多**，应更多用系统语义色与单一 accent。
11. **空白使用过度**：内边距 24/28、垂直间隙偏大，大窗口内容利用率低。

### 优先执行
P0 信息架构（去掉大字标题/彩色眉标/仪表盘，页面差异化）→ P1 Sidebar/List/Detail（系统密度）→ P2 排版/间距/颜色 → P3 Toolbar/Inspector/Context Menu → P4 Hover/动效/打磨。

### 第三轮实现记录（UI 深度重设计，已完成）
- 共享组件新增 `PageTitle`（原生导航式小标题：14pt semibold + 11pt subtitle），`ListRowContainer`（紧凑行容器、蓝色选中态）。
- Sidebar 重写：品牌贴片/大胶囊选中态移除；改为系统 `underPageBackgroundColor`、14pt 图标、28pt 行高、6pt 圆角淡蓝选中、真实分组（RIVER / MEMORY / SYSTEM），底部"写一句"+记录状态轻量化，列宽收敛到 182。
- Today：大衬线标题/彩色眉标/四格 KPI 移除；改为 `PageTitle` + 右侧日期导航，概览合并为一条紧凑 meta 行（已记录·快记·专注·继续·采集）。头部"写一句"移除（由 Toolbar 承担，避免重复）。
- Memory：大标题改 `PageTitle`，行更密（预览换系统 13pt medium），间距收敛。
- Ask：居中大标题 + 居中输入改为左上紧凑 `PageTitle` + 左对齐输入、建议、结果（消除 ChatGPT 克隆大空白）。
- Settings：标题改 `PageTitle`，间距收敛。
- Inspector/Timeline：衬线标题换系统标题，内边距 20→16。
- 验收：swift build 通过；swift test 93 项通过；`dist/RiverDiaryMac.app` 重新打包并已启动运行。
- 限制：沙盒环境无屏幕录制权限，无法输出真实截图，视觉以“可运行 + 代码层审查”为准。
