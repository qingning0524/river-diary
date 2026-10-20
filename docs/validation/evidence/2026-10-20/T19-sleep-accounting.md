# T19 睡眠汇总口径：未分期、重叠与“未知≠0”

日期：2026-10-20（Asia/Shanghai）
状态：**T19 睡眠口径与健康来源状态已落地并有确定性测试；午睡界面呈现与真机样本仍待。**

## 1. 修复前的问题

iOS `HealthKitStore.aggregate(samples:)` 直接按样本累加：

- 只处理 `asleepCore / asleepDeep / asleepREM / awake`，**忽略 `asleepUnspecified`**：只上报“睡着了”的设备/来源会被算成 0 小时；
- 多个来源（Watch + iPhone）对同一段睡眠重复上报时**重复累加**；
- 按样本 `endDate` 的 `startOfDay` 分夜，跨午夜本身没问题，但**没有任何并集/去重**；
- 只有 `awake`/`inBed` 记录的夜晚会生成 `total = 0` 的对象，界面显示“睡了 0 小时”，把“未知”说成“零”；
- 平均值、洞察对照、写回健康事件都直接使用 `totalHours`，未知夜晚会拉低平均或写成 0 小时事件。

## 2. 改动

### 共享聚合器（RiverDiaryCore）

新增 `SleepAggregation.swift`：

| 概念 | 规则 |
|---|---|
| `ObservedSleepInterval` | 平台无关的睡眠区间，阶段含 core/deep/rem/unspecified/awake/inBed |
| `asleepSeconds` | 所有睡着阶段（含未分期）的**并集**；多来源重叠只算一次 |
| `stageCoverage` | 每个分期自己的并集覆盖；**允许相加大于总睡眠**，只回答“分期覆盖多少” |
| `hasAsleepSamples` | 这一夜是否有任何睡着样本；false 表示只有清醒/在床，属于未知 |
| 日期归属 | 按醒来那天的 `startOfDay` 分夜，日历/时区由调用方传入，口径可控 |
| 无效区间 | 结束不晚于开始的样本直接忽略 |

### iOS 接入

- `SleepNight` 增加 `unspecified` 与 `hasAsleepSamples`；`total` 计入未分期；
- `HealthKitStore` 把 HealthKit 样本映射成 `ObservedSleepInterval` 后交给聚合器；
- `averageSleepHours` 只统计有睡着样本的夜晚；
- `RiverNodeStore.recordHealthSnapshot` 跳过未知夜晚，避免把 0 小时写进健康事件；
- 今日页睡眠卡与洞察的“睡眠-心情”对照都跳过未知夜晚。

### 来源优先级

同一段睡眠常被 Apple Watch 与 iPhone 同时上报，而且结论可能冲突（Watch 说分期睡着，iPhone 只给笼统区间或清醒片段）。本轮给区间加了 `sourcePriority`：

- 高优先级来源先“认领”时间段，低优先级只能补上没被认领的片段；
- 同优先级之间不互斥，仍按并集去重（保持原有行为）；
- iOS 映射：`Watch → 20`、`iPhone → 10`、其他来源/手动 → `5`。

这样 Watch 的分期不会被 iPhone 的粗粒度样本覆盖，iPhone 也能在 Watch 没记录的时间段补足。

## 3. 验证

新增 `SleepAggregationTests`（13 项，全部确定性）。前 8 项覆盖口径本身：

1. 只有未分期的睡眠仍计入总时长；
2. 重复来源重叠时总量只算一次，分期覆盖各自去重；
3. 分期互相重叠时总睡眠取并集、分期覆盖允许大于总时长；
4. 只有 `inBed`/`awake` 时 `hasAsleepSamples == false`，不产生“0 小时”；
5. 23:00→07:00 归属醒来的那天，整段计入；
6. 零长度/倒置区间被忽略；
7. 多夜按醒来日分组并倒序；
8. 并集算法处理嵌套与相邻区间。

后 5 项覆盖来源优先级：

9. 高优先级睡着覆盖低优先级清醒；
10. 低优先级只补高优先级未覆盖的时段；
11. 高优先级清醒裁掉低优先级睡眠；
12. 同优先级重叠仍然只算一次；
13. 高优先级分期的覆盖会裁掉低优先级分期的重叠部分。

结果：

- `swift test --package-path Packages/RiverDiaryCore`：Swift Testing **85 项通过**（5 suite），XCTest **15 项通过**；
- iOS Debug 模拟器构建成功（新增 Core 依赖的 `import RiverDiaryCore` 已补）。

## 3.5 归属口径版本化：午睡与旅行时区

原先“按醒来日分夜”只是隐含规则，白天补觉和旅行改时区会被静默重解释。本轮把它变成显式、带版本的口径：

- 新增 `SleepNightPolicy`（当前 `v1`）：
  - 按醒来日分夜；
  - 一段连续睡眠 **≤3 小时且开始于 06:00–20:00** 记为午睡；其余算夜间睡眠；
- `ObservedSleepNight` 增加：
  - `napSeconds` 与 `nightSeconds = asleepSeconds - napSeconds`；
  - `policyVersion` 与 `timeZoneIdentifier`，让每条汇总都能解释“按哪套规则、哪个时区”算出来；
- 调用方必须显式传日历；同一份样本用 UTC 与东八区会分到不同日期（测试验证）。

新增 7 项测试（睡眠共 20 项）：午后 30 分钟午睡与 8 小时夜眠分开、凌晨短睡不算午睡、白天超 3 小时不算午睡、
多次午睡累加、阈值可由 policy 覆盖、版本与时区写入结果、同一样本随时区分桶。

iOS `SleepNight` 已带 `nap` 字段（总睡眠仍包含午睡）；界面展示尚未改动。

## 3.6 健康来源状态：未知 ≠ 无样本 ≠ 陈旧 ≠ 失败

新增 `HealthSourceStatusEvaluator`（RiverDiaryCore），状态：

| 状态 | 含义 |
|---|---|
| `unsupported` | 设备/系统没有该来源 |
| `unknown` | 无法确认权限或状态（如 HealthKit 读权限不可查询） |
| `notAuthorized` | 明确被拒绝 |
| `noSamples` | 已确认可用但没有样本（不是“零”，也不是失败） |
| `healthy` | 最近样本在阈值内 |
| `stale` | 有样本，但最近一次已超过阈值（默认 36 小时） |
| `failed` | 最近一次读取的真实错误，优先于授权判断 |

关键规则：

- 失败永远优先：请求已经失败时不再宣称“已授权”；
- `unknown` 与 `noSamples` 分开；只有明确知道“可用但没样本”才报 `noSamples`；
- 有样本时以数据说话：即使授权未知，也能得到 `healthy`/`stale`；
- 有样本却没有时间戳 → `unknown`，不猜新旧；
- 阈值由 `HealthSourcePolicy` 控制，边界为“超过才陈旧”。

测试：`HealthSourceStatusTests`（11 项）覆盖不支持、失败优先、明确拒绝、正常、陈旧、边界、无样本、
HealthKit 式未知授权、样本优先、缺时间戳、自定义阈值。

iOS `HealthKitStore` 已暴露 `sourceStatus`：授权状态固定传 `nil`（读权限不可查询），
由样本/失败决定；界面尚未展示。

## 4. 仍未完成

- **界面呈现**：午睡与来源状态都已有数据，但还没有在今日卡/回顾/设置里展示；跨时区飞行的历史数据仍按当前时区分桶，需要 UI 解释“按哪个时区”。
- **界面文案**：未知夜晚不再显示 0，但还没有“未记录睡眠”的明确文案与引导。
- **真机样本与测试**：iOS 单元测试 runner 仍不可用（T23），本轮只有编译验证；真实 Watch/iPhone 双来源样本未测。
- **历史数据**：已经写入的 0 小时健康事件不会被自动改写；是否需要追溯标记为未知需单独迁移设计。
