# RIVER UI REDESIGN — Personal Memory OS 界面重新设计

> 分析产物，日期：2026-09-19。
> 这是“UI 如何重思”的设计文档，不含 UI 代码。所有“删除”都指“从 App 导航与界面移除”，
> 涉及用户数据与对应代码必先做 CODE_MAP 标记（ARCHIVE/DELETE），不破坏用户手写内容。

---

## 0. 现状结构（审计证据）

当前主界面 `RootView` 是：固定 Sidebar + 固定主内容 + 顶部条，**没有 Inspector**。

Sidebar 入口（`AppDestination`）：`日记 / 时间线 / 记忆 / 洞察 / 设置`

| 顶层 | 次级 Tab | 实际内容 |
|---|---|---|
| 日记 Today | 无 | 头部 + 写作台 + 右侧卡片（当日素材、随手留下、写作协助、AI 回顾、身体信号） |
| 时间线 Time | 时间线 / 情绪河 / 节律 | ActivityView（时间线）、RiverView（情绪河）、RhythmView（节律/脉冲） |
| 记忆 Memory | 记忆库 / AI 搜索 / 随笔 | MemoryArchiveView、AI 搜索 UI、NotesView |
| 洞察 Insight | 无 | AIAnalysisView（六件套分析卡片） |
| 设置 System | 偏好设置 / 高级数据 | PrivacyView、DataExplorerView（跨天查询/数据库页） |

观察结论（直接支撑本次重设计）：
1. 顶级导航是“功能组织”的（每个功能一个入口），不是“记忆组织”的。
2. Today 是“写日记 + Dashboard 素材栏”，时间线反而藏在二级。
3. 页面之间用大量 Card / Tab / 渐变胶囊承载，视觉上是 SaaS Dashboard。
4. 没有“点击片段 → 右侧证据详情”的纵向结构，事件详情被塞进独立大页面。
5. Insight、情绪河、节律、高级数据都是“报表页面”，不符合记忆优先目标。

---

## 1. 应删除的页面

以下一律**从界面导航移除**，落到 `ARCHIVE` 代码标记，不立即删除数据与代码，等待后续 CLEANUP Phase 再按依赖删除。

| 现存页面/入口 | 处置 | 理由 |
|---|---|---|
| 顶层「洞察 Insight」 | 删除入口 | 它的内容应下沉到 Ask / Today Inspector，不再作为一级目的地 |
| 「时间线」的次级 Tab「情绪河 River」 | 删除入口 | 是图表页，情绪应作为日期/片段的元数据保留，不做首页可视化 |
| 「时间线」的次级 Tab「节律 Rhythm / 脉冲」 | 删除入口 | 同上；月度回顾功能视未来需求并入 Memory |
| 「记忆」的次级 Tab「AI 搜索」 | 删除入口 | AI 搜索在 Ask 中成为一等体验，不再藏在 Memory 二级 |
| 「记忆」的次级 Tab「随笔 Notes」 | 合并 | 随笔并入新的 Memory（本地搜索 + 按天文字），不作为独立 Tab |
| 「设置」的次级 Tab「高级数据 DataExplorer」 | 删除页面 | 用户不应看数据库/跨天 SQL 式页面；跨天查询由 Ask 承担 |
| Today 右侧「素材 / AI 协助 / 身体信号」卡片栏 | 删除布局 | 这是 Dashboard 形态；保留“写日记”能力，但改到时间线旁边/Inspector 内，不用卡片墙 |
| 强制 AI 连接门禁（`AIRequiredSetupView` 不可跳过） | 删除门禁 | 与“无 AI 可用”“Recalls 不是 SaaS”目标冲突；改为可选连接 |

> 删除原则：删的是**信息架构与导航层**，不是删除真实数据。日记原文、快记、健康、AI 归档都继续保留在数据层。

---

## 2. 应保留的页面

| 页面 | 保留方式 |
|---|---|
| Today | 保留语义，**重定位为时间线首页**；日期可切换，默认为今天 |
| Memory | 保留，重构为“过去 + 长期记忆”，不再分三个 Tab |
| MenuBar 快记 | 保留，作为第一快速入口 |
| 日记写作 | 保留为“书写面”，从 Today 右侧卡片墙移到一个安静位置（页头“写一句”或今日 Inspector） |
| 设置 | 保留，收敛为 Recording / Model / Privacy / Data 四区；去掉高级数据页 |
| 本机回顾 / 本地问答 | 保留业务逻辑，迁入 Ask 的离线后端（`LocalReview`、`ActivityChatEngine`） |
| 河流信 / 快记 / 整理 Comment | 保留为用户内容，放 Memory/今日详情中，不作为图表页 |

---

## 3. 新 Navigation Architecture

采用 macOS `NavigationSplitView`：

```
Window
├── Sidebar（固定，窄）
│     River
│     Today         (⌘1)
│     Memory        (⌘2)
│     Ask           (⌘3)
│     ──────────
│     Settings      (⌘,)
│     ──────────
│     ●  Recording…   （静默状态点，不跳动）
│
├── Content（主内容）
│     Today      → 一天的时间线（NOW + Episodes）
│     Memory     → 搜索 + Recent / Projects / Important
│     Ask        → 居中输入 + 有证据的回答
│     Settings   → 四区偏好
│
└── Inspector（可选，默认隐藏，宽度 ~320–380pt）
      Episode 详情
      Memory 详情
      Ask 回答的 Evidence
```

关键规则：
- Inspector 由 Content 里的**选择**驱动，永不替换主内容。
- 无全局“十二月粒子 / 渐变小行星 / 状态饼”。
- 顶层只有 4 个入口 + 设置。
- 每个顶层页面有且只有一个主任务：看今天 / 找回过去 / 问过去 / 管理记录。

---

## 4. ASCII Wireframe

### 4.1 窗口骨架（Today + Inspector 打开）

```
┌────────────┬──────────────────────────────────────┬───────────────────┐
│  Sidebar   │  Content                             │  Inspector        │
│            │                                      │                   │
│ River      │  Today                   2026-09-19  │  Developing River │
│            │  River has been recording 6h 42m.    │  14:02 — 16:37    │
│ Today      │                                      │  2h 35m           │
│ Memory     │  09:12                               │  ───────────────  │
│ Ask        │    ●  Developing River               │  Summary          │
│            │    │   1h 42m  ·  Xcode               │  主要进行了 ……    │
│ ─────────  │    │                                 │  ───────────────  │
│ Settings   │  11:03                               │  Evidence         │
│            │    ●  Reading docs                   │  14:02 Xcode      │
│ ─────────  │    │   32m    ·  Safari               │  14:49 Safari     │
│ ● recording│  11:35                               │  15:04 Xcode      │
│            │    │    (writing a quick note)       │  ───────────────  │
│            │  11:47                               │  Confidence · High│
│            │    │    ...                          │  [ Correct ]      │
│            │  ○  NOW  ·  未开始的下一个片段        │  [ Edit ]         │
│            │  ●  13:20  Xcode  (current, 38 min)  │                   │
│            │                                      │                   │
└────────────┴──────────────────────────────────────┴───────────────────┘
```

`●` = Episode 开始点，`│` = 时间线连续线，`○ …` 下一片段。
Inspector 默认隐藏，点击线段/Episode 才滑入。

### 4.2 Today（无 Inspector）

```
┌──────────────────────────────────────────────┐
│ Today                         2026-09-19     │
│ River has been recording 6h 42m.            │
│──────────────────────────────────────────────│
│ 09:12                                        │
│    ● Developing River                        │
│    │  1h 42m                                 │
│    │    主要进行了 macOS Memory OS 重构…       │
│    │                                         │
│ 11:03                                        │
│    ● Reading documentation                   │
│    │  32m · Safari                           │
│                                              │
│ ○ 13:20   Xcode  (current)                   │
│                                            │
└──────────────────────────────────────────────┘
```

完整字段与“迷你卡片”无关：时间轴左边是小时刻度，中间是 Timeline line，右边是文本。

### 4.3 Memory

```
┌──────────────────────────────────────────────┐
│ Memory                                       │
│ ┌──────────────────────────────────────────┐ │
│ │ Search your past…                        │ │
│ └──────────────────────────────────────────┘ │
│                                              │
│ Recent                                       │
│  · 09-12  完成了 V2 架构草图             2 ep│
│  · 09-10  根治数据库日期问题             1 ep│
│  · 09-08  模型接入调试                   3 ep│
│                                              │
│ Projects                                     │
│  · River V2（3 周 · 24 ep）                │
│  · 相机收纳（1 周 · 5 ep）                  │
│                                              │
│ Important                                    │
│  · 确认：长期使用 dayKey=UTC&本地混合  1 ep  │
│                                              │
└──────────────────────────────────────────────┘
```

Memory 顶部只有一行搜索，下面是最新的记忆列表，不是再次 Timeline。

### 4.4 Ask

```
┌──────────────────────────────────────────────┐
│                  Ask River                    │
│                                              │
│   What have I been working on this week?     │
│                                              │
│  ── Based on 7 episodes ──────────────────   │
│                                              │
│  “这周主要在做 River 的 Memory OS 重构：      │
│    Episode Engine →            证据 →        │
│    Memory provenance →        查看证据       │
│    数据库迁移验证 →            查看证据”      │
│                                              │
│  [ search ]                                  │
└──────────────────────────────────────────────┘
```

回答里带证据的可点击段落“Based on 7 episodes”打开 Inspector（或小下划证据抽屉）。

### 4.5 Settings（简版）

```
Settings
  Recording     权限/数据源/开关/保留期
  Model         连接状态/模型/是否发送窗口标题
  Privacy       加密/备份/导出/清除（分层）
  Data          来源健康面板（只读状态，不含数据库页）
```

---

## 5. Component Map

新组件（原生 SwiftUI）：

| 组件 | 职责 | 旧对应 |
|---|---|---|
| `RiverShell` | NavigationSplitView + Sidebar + Inspector 容器 | `RootView` 改造 |
| `SidebarList` | Today / Memory / Ask / Settings + 状态点 | 现有 sidebar 重构 |
| `DayHeader` | Today 标题 + 日期 + 一句记录时长 | `TodayView.header` |
| `TimelineView` | 主时间线（whitespace + line + rows） | `DayTimelineView` 重构 |
| `EpisodeRow` | 单个 Episode（字重层级，无卡） | `TimelineSegmentCard` 收敛 |
| `NowRow` | 当前活动行，克制动效 | `activeSession` 展示 |
| `EpisodeInspector` | Summary + Evidence + Confidence + Correct/Edit | 新建 Inspector |
| `EvidenceList` | 时间 + 来源 + 内容（最重要） | `TimelineSegmentCardView` 的 evidence 部分 |
| `SourceTag` | 应用名 / Safari / 本地文件 小标签 | 现有 source label 重构 |
| `ConfidenceBadge` | High/Medium/Low/Unknown | `ActivityConfidenceEngine` 结果接入 |
| `MemoryPage` | 搜索 + Recent/Projects/Important | `MemoryView` 重构 |
| `MemoryItemRow` | 记忆条目（标题/时间/简短/Episode 数） | `MemoryArchiveDay` |
| `AskPage` | 居中输入 + 证据化回答 | 原 AI 搜索 + Insight 融合 |
| `AnswerBlock` | 回答 + 证据引用 chips | `AIAnalysisView` 收敛 |
| `EvidenceReferenceChip` | “Based on 7 episodes” 可点击 | 新 |
| `SettingsPage` | 四区偏好 | `PrivacyView` + 移除 DataExplorer |
| `EmptyStateLine` | 安静空态（一行文字） | 现大字占位重构 |

**不要建**每个小组件的 ViewModel；状态仍集中在少量 Store，组件只接收参数与回调。

---

## 6. UI Migration Plan

约束：一次只动一个顶层；每步可 Build / 跑 80 项测试 / Commit / 回滚；每步结束输出状态报告并等待确认。

| 步 | 内容 | 判定 |
|---|---|---|
| M1 | 建 `NavigationSplitView` 壳 + Inspector 容器；**原有五个页面原样搬进 Content**，静态占位 Inspector 隐藏 | 主界面仍是 5 入口但已有 split 结构；Build+测试绿 |
| M2 | 加 `Inspector` 空容器与 Selection 状态机；把今日/时间线的点击行为从“跳页”改为“select → 显示 Inspector” | 不删旧页面；记录交互行为更换 |
| M3 | 重构 Today：删除右侧卡片栏；时间线成为主内容；日书写改为页头/Inspector 入口；加 NOW 行 | Today 不再是 Dashboard |
| M4 | 把「时间线」顶级并入 Today（日期切换）；「情绪河/节律」从导航移除，标记 ARCHIVE | 顶层只剩 4 + Settings |
| M5 | 重构 Memory：搜索框 + Recent/Projects/Important；「AI 搜索/随笔」Tab 移除；本地文字并入 | Memory 不是第二个 Timeline |
| M6 | 新建 Ask：居中输入 + 证据化回答 + Inspector 证据引用；把 Insight/AI 搜索业务迁入 | 去除 Insight 顶级入口 |
| M7 | 重构 Settings：Recording/Model/Privacy/Data；移除「高级数据」页 | 设置收敛 |
| M8 | 移除强制 AI 连接门禁；无 AI 时进入安静空态与本地 Ask | 产品定位一致 |
| M9 | 视觉对齐：Typography / semantic colors / motion 规则统一实现 | 全部完成重做 UI 设计目标 |
| M10 | Review & 回归：80 项测试 + 交互验收（Today/Memory/Ask/Inspector/空态） | Done |

Migration 不混入数据层重构；数据层（V2 Store）按 `RIVER_REFACTOR_PLAN.md` 独立推进，UI 先接旧数据读取，后续再换 Store。

---

## 7. 最终体验验收

- 打开 = 今天。第二眼 = 时间线。第三眼 = 做过什么。
- 点击 Episode = Inspector 显示 **Evidence > AI 分析**。
- Memory 让“过去”可被检索与沉淀。
- Ask 让“问自己的过去”有答案且可回到证据。
- 无 AI、无网络时应用依然安静可用，并能诚实回答“不知道”。
- 视觉自律：系统字体、semantic colors、timeline 连续线、Inspector 滑入，无紫色渐变、无大欢迎横幅、无粒子。

> 等待确认后再开始任意 UI 代码改动。
