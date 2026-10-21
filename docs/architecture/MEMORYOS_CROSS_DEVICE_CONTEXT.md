# MemoryOS 跨端设备上下文

状态：**Mac / iPhone 双端 DayContext 写入、双端展示、网页 mirror 渲染已落地；真实双机复制与网页导入仍待验收**。本文描述当前实现与边界；产品取舍以 [主规划](../../主规划.md) 为准。

## 1. 解决什么问题

此前数据源是“按端采集、按端展示”：

- Mac 的浏览器、备忘录正文、Markdown、Kindle 主要写旧混合库，iPhone 看不到。
- Mac 的日历/天气/Git 是 V2 Event，iPhone 能收到但界面不渲染。
- iPhone 的训练、State of Mind、屏幕时间、语音速记是 V2 Event，Mac 不合并、不展示。
- 网页副本只从旧版 `DiaryData` 转换，没有 V2 和 Mac 上下文。

MemoryOS 的目标是：**任一端采集的事实，都能在另一端和网页被读到**，同时不把敏感原文无条件搬来搬去。

## 2. 方案：设备日上下文

新增 `DayContextSnapshot`（`Packages/RiverDiaryCore/Sources/RiverDiaryCore/DayContextSnapshot.swift`）：

```text
DayContextSnapshot
  deviceID / deviceName / day / generatedAt
  sections[]
    kind       browser | notes | markdown | kindle | calendar | weather |
               git | focus | screenTime | health | workout | stateOfMind |
               voice | apps
    title      给用户看的标题
    summary    一行摘要
    items[]    title / detail / count / at
```

它是**投影**，不是新的事实库：

- 原始证据仍在 `RawEvent` / `RiverEvent` 与旧混合库；全文开关同时产生独立证据事件和更完整的 DayContext。
- 快照只放用户可读的摘要、标题、计数和短摘录；不放 URL 全量、备忘录全文、照片、健康原始样本。
- 每个设备每天一份；内容变化时用内容哈希生成新 Event ID，读取时取同设备同天最新一条。
- Event payload 同时带 `text`（section 摘要 + item 标题）供现有全文检索使用；`contextJSON` 才是完整快照。

## 3. 传输

两端都把快照写成 V2 Event：

| 端 | source | kind | payload |
|---|---|---|---|
| Mac | `dayContext` | `dayContextSnapshot` | `RawEventPayload.contextJSON` |
| iPhone | `day_context` | `dayContextSnapshot` | `RiverEventPayload.contextJSON` |

事件按现有 River Node 加密复制走：本机 Event 分配 `originDeviceID` / `originSequence`，经 iCloud Drive 或 LAN 到另一台设备。没有新增同步通道，也没有新增服务端接口。

### 发布时机

- **Mac**：每日采集结束、写完日历/天气/Git/Markdown/Kindle/备忘录后发布。只在该日至少有一个 section 时发布。
- **iPhone**：健康快照写入后、记录屏幕时间后、记录语音速记后发布；另外 `refreshDayContext()` 可在回到前台时补发。没有 section 时不发布。
- 同一天多次发布：内容相同则稳定 Event ID 去重；内容变化则新事件，展示层取最新。

## 4. 双端展示

### iPhone

- **今日页**：`其他设备的一天` 卡片，按设备分组，显示每个 section 的摘要和前两条 item，并提供“查看全部上下文”详情页；自己的设备不重复显示。
- **时间线**：`RiverIOSProjection` 增加一条 `设备上下文` 行，标题为“Mac 的一天”，详情为各 section 摘要；点击走已有事件详情。
- 打开逐来源全文同步后，时间线再按来源各聚合成一条 `Mac 浏览器/备忘录/Markdown/Kindle（N）` 证据行，带前几条标题/短摘录，供搜索；不会把几百条浏览记录逐条铺开。
- 设备上下文卡提供“查看 Mac 原始明细”，按来源展开最多 200 条标题/正文/URL/时间；这是只读证据视图，不写回。
- 数据来自 `db.events(from:to:)` 的 `dayContextSnapshot`，只展示 `deviceID != 本机` 的快照。

### Mac

- **今日页**：`其他设备的一天` 面板，读取 `V2Store.rawEvents`，按设备+天取最新，过滤本机。
- 每个 section 显示标题、摘要和前两条 item；点“查看全部”打开只读详情。
- 数据源设置页仍负责各来源的采集开关与失败状态；日上下文面板只负责“对方设备看到了什么”。

## 5. 网页

### 5.1 mirror v2

原生导出升级为 `river.memory-mirror` **v2**：日记 entries 之外增加顶层 `contexts`：

```json
{
  "format": "river.memory-mirror",
  "version": 2,
  "entries": [ ... ],
  "contexts": [
    {
      "deviceID": "device-a",
      "deviceName": "Mac",
      "day": "2026-10-21",
      "generatedAt": "2026-10-21T22:30:00Z",
      "sections": [
        { "kind": "notes", "title": "备忘录", "summary": "2 条",
          "items": [{ "title": "窗边", "detail": "去河边走走。" }] }
      ]
    }
  ]
}
```

- 网页把每个 context 映射成只读 `kind=context` 卡片，ID 为 `context-<device>-<day>`；参与长河筛选、搜索、合集与"问 River"检索。
- 日期用 ISO8601；ID 只保留字母、数字、`-`、`_`，满足网页显式 ID 规则。
- 继续兼容 v1：旧 entries 或旧 context entry 仍可导入；新网页读 v1 不会要求 contexts。

### 5.2 导出与云空间

- Mac：设置 → 隐私与备份 → 网页控制台副本；iPhone：设置 → 导出我的记录 → 网页控制台。
- 导出内容 = 当前设备可读的旧版日记 + **双端已经复制到本机的设备上下文**。如果本机没有日记但有上下文，也允许只导出上下文。
- 网页导入仍是手动文件；云空间仍是用户在浏览器端设置口令后上传密文。**没有自动上传，也没有把口令交给服务端。**
- 云空间的加密 payload 已包含 `contexts`；解密后仍会经过 `normalizeArchive`，因此云空间副本不会丢掉设备上下文。
- 想看另一台设备的上下文，前提是那台设备的 Event 已同步到当前设备；导出的是"当前设备已知"的镜像，不是服务端全量。

## 6. 隐私边界

| 数据 | 是否进快照 | 说明 |
|---|---|---|
| 浏览器访问数、Top 域名、前几条标题 | 是 | 默认不复制完整 URL；Mac 设置可逐项打开 URL 同步，开启后另写 `urlVisit` 证据事件（≤500/天） |
| 备忘录/Markdown/Kindle 标题、短摘录 | 是 | 默认每条最多 160 字；Mac 设置可逐项打开全文同步（单条 20,000 字），开启后另写 `noteModified` 证据事件 |
| 日历标题、时间、完成提醒标题 | 是 | 不复制备注、参与者姓名 |
| Git 仓库名、提交数 | 是 | 不复制 commit message、作者、diff |
| 健康睡眠/步数/训练/心情效价 | 是 | 只放摘要，不放原始样本 |
| 屏幕分钟、专注分钟 | 是 | 不放应用使用明细全量 |
| 语音速记文字 | 是（前 120 字/条） | 不保存音频 |
| 照片、窗口标题、位置原始坐标 | 否 | 仍只在原生产生端 |

这不是"所有原文跨端"；它是**跨端可读的最小充分上下文**。需要全文时，应逐来源增加显式开关，而不是默认复制。

## 7. 已知限制

1. 快照是摘要，不是完整浏览器历史/笔记全文；手机和网页看到的是"Mac 的一天"，不是逐条原始证据。
2. 只有已复制到本机的 Event 才会出现在导出里；两台设备长时间离线时，镜像会滞后。
3. 网页仍是只读镜像：手动导入或浏览器端云空间口令解密；没有登录即自动同步。
4. iOS 17 没有 State of Mind；该 section 不会出现，也不能显示成"零条心情"。
5. 卡片只展示前几条；详情页展示快照内的全部 item。默认快照是摘要；Mac 设置里可逐来源打开“浏览器 URL / 备忘录正文 / Markdown 正文 / Kindle 划线全文”同步，开启后仍受单条 20,000 字与每类 20 条限制。按来源展开与搜索高亮仍是后续。
6. 真实双机 iCloud/LAN 复制、网页导入 context、云空间双设备流程尚未做真机验收。

## 8. 验证与文件

- Core：全量 91 项通过（含 `DayContextSnapshotTests` 2 项：ISO8601 往返、mirror context entry）。
- Mac：`MacDayContextBuilderTests` 3 项 + `MacRawEventBuilderTests` 2 项；全量隔离测试 483 项通过。
- Web：`memory-core.test.mjs` 增加 context/v2 归一化用例；当前 38 项通过。
- iOS：模拟器 Debug 构建通过；新增 `IPhoneDayContextBuilderTests`，测试 bundle `TEST BUILD SUCCEEDED`；两次模拟器运行均在启动测试前挂起（非测试失败），未取得执行结果。

关键文件：

- `Packages/RiverDiaryCore/Sources/RiverDiaryCore/DayContextSnapshot.swift`
- `Packages/RiverDiaryCore/Sources/RiverDiaryCore/MemoryMirrorExport.swift`
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/Infrastructure/Ingestion/MacDayContextBuilder.swift`
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/Infrastructure/Ingestion/DataIngestionStore.swift`
- `ios/RiverDiary/RiverDiary/Infrastructure/Ingestion/IPhoneDayContextBuilder.swift`
- `ios/RiverDiary/RiverDiary/Infrastructure/Sync/RiverNodeStore.swift`
- `ios/RiverDiary/RiverDiary/Views/RiverAutomaticTodayView.swift`
- `ios/RiverDiary/RiverDiary/Views/IOSExperience.swift`
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/Views/TodayDashboardView.swift`
- `website/user/assets/memory-core.js`、`website/user/assets/app.js`
