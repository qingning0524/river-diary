# MemoryOS 跨端设备上下文（2026-10-21）

## 1. 背景

数据源采集此前是“按端落盘”：Mac 的浏览器、备忘录正文、Markdown、Kindle 只在旧混合库；Mac 的日历/天气/Git 虽写 V2，但 iPhone 不展示；iPhone 的训练/心情/屏幕时间/语音速记虽写 V2，但 Mac 不展示；网页副本只从旧版 `DiaryData` 导出。

本轮把“设备日上下文”作为跨端投影补齐：**Mac 和 iPhone 都发布 DayContext，双端 Today/时间线都展示对方，网页镜像也带上。**

## 2. 本轮改动

### 2.1 Core

- 新增 `DayContextSnapshot` / `DayContextSection` / `DayContextItem`。
  - `deviceID`、`deviceName`、`day`、`generatedAt`、`sections`。
  - section 覆盖 browser / notes / markdown / kindle / calendar / weather / git / focus / screenTime / health / workout / stateOfMind / voice / apps。
  - 编码用 ISO8601，稳定 ID `deviceID|day`。
- `RiverEventPayload` 与 Mac `RawEventPayload` 增加 `contextJSON`。
- `MemoryMirrorArchive` 增加：
  - `empty(exportedAt:)`：允许只有上下文、没有旧版日记的导出。
  - `appendingContexts(_:)`：把快照写进顶层 `contexts`（mirror v2）。
  - `contextEntry(from:)`：网页可读的标题、正文、facts、tags、source。

### 2.2 Mac

- 新增 `MacDayContextBuilder`：把浏览器、备忘录、Markdown、Kindle、日历/提醒、天气、Git、专注、屏幕压成 sections。
  - 敏感边界：浏览器只放访问数/Top 域名/前几条标题；笔记只放标题 + 160 字短摘录；Git 只放仓库名 + 提交数。
- `DataIngestionStore` 在每日采集结束发布 `dayContextSnapshot` Event；payload 同时写 `text` 摘要供搜索。
- 新增逐来源全文开关：浏览器 URL、备忘录正文、Markdown 正文、Kindle 划线；默认关闭，开启后仍受 20,000 字/20 条上限。
- 全文开关同时把明细写成独立 V2 证据事件（`urlVisit` / `noteModified`，浏览最多 500 条/天）；iPhone 时间线按来源聚合成证据行，带前几条标题/摘录供搜索，不逐条铺开。
- `dayContextSnapshots(for:)`：Today 面板读取其他设备的快照，同设备同天取最新。
- `dayContextSnapshotsForWeb()`：网页镜像导出用，最多 400 天。
- `TodayDashboardView` 新增“其他设备的一天”面板。
- 网页副本导出改为 `store.webMirrorData(contexts: ingestion.dayContextSnapshotsForWeb())`。

### 2.3 iPhone

- 新增 `IPhoneDayContextBuilder`：从当天 V2 Event 提取健康、训练、心情、屏幕时间、语音速记、应用开关。
- 发布时机：健康快照写入后、记录屏幕时间后、记录语音速记后；`refreshDayContext()` 可补发。
- `RiverNodeStore.dayContextSnapshotsForWeb()` 提供镜像数据。
- 今日页新增“其他设备的一天”卡片与“查看全部”详情；时间线新增设备上下文行。
- 网页副本导出改为带 contexts。
- 网页云空间的加密 payload 也带 `contexts`，解密后仍可映射成设备上下文卡片。

### 2.4 Web

- `memory-core.js` 接受 `kind=context` 与 `source.type=context`。
- 长河类型筛选增加“设备上下文”；context 参与搜索、合集、问 River 检索。
- 旧 v1 镜像不认识的 `context` 会按普通 entry 读取，不会崩。

## 3. 验证

- Core：全量 91 项通过（含 `DayContextSnapshotTests` 2 项）。
- Mac：`MacDayContextBuilderTests` 3 项、`MacRawEventBuilderTests` 2 项通过；全量隔离测试 **483 项通过，0 失败**。
- Web：`node --test website/user/tests/*.test.mjs` 38 项通过（新增 v2 contexts 归一化）。
- iOS：模拟器 Debug 构建通过；新增 `IPhoneDayContextBuilderTests`，测试 bundle `TEST BUILD SUCCEEDED`；两次模拟器运行均在启动测试前挂起（非测试失败），未取得执行结果。Mac `.app` 重新打包通过。
- 未运行：iOS 单元/UI 测试、真实双机复制、网页导入 context、云空间双设备流程。

## 4. 已知限制

- 快照是摘要，不是完整原文；浏览器只保留 Top 域名/前几条标题，笔记每条 160 字。
- 只有已复制到本机的 Event 才能被导出；离线设备会滞后。
- 网页仍依赖手动导入或浏览器端云空间口令，没有自动上传。
- iOS 17 没有 State of Mind section。
- section 只展示前几条 item；完整列表/展开/搜索高亮仍待做。
- 页面布局与真机阅读效果需要人工验收。
