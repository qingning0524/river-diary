# T19 睡眠汇总口径：未分期、重叠与“未知≠0”

日期：2026-10-20（Asia/Shanghai）
状态：**T19 睡眠汇总部分修复并有确定性测试；来源优先级、跨日/旅行时区口径与真机样本仍待。**

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

## 3. 验证

新增 `SleepAggregationTests`（8 项，全部确定性）：

1. 只有未分期的睡眠仍计入总时长；
2. 重复来源重叠时总量只算一次，分期覆盖各自去重；
3. 分期互相重叠时总睡眠取并集、分期覆盖允许大于总时长；
4. 只有 `inBed`/`awake` 时 `hasAsleepSamples == false`，不产生“0 小时”；
5. 23:00→07:00 归属醒来的那天，整段计入；
6. 零长度/倒置区间被忽略；
7. 多夜按醒来日分组并倒序；
8. 并集算法处理嵌套与相邻区间。

结果：

- `swift test --package-path Packages/RiverDiaryCore`：Swift Testing **62 项通过**（4 suite），账号 XCTest **8 项通过**；
- iOS Debug 模拟器构建成功（新增 Core 依赖的 `import RiverDiaryCore` 已补）。

## 4. 仍未完成

- **来源优先级**：目前是所有来源并集，没有“优先 Apple Watch、其次 iPhone”的口径；重复来源的差异会在并集里被抹平。
- **跨午夜/午睡/旅行时区版本化**：聚合器接受调用方日历，但没有把“一夜”的窗口规则写成版本化配置；跨时区飞行、白天补觉仍按醒来日粗分。
- **健康来源状态**：已连接/无样本/失败/陈旧/未支持仍未在聚合层区分，只有空数组与错误码。
- **界面文案**：未知夜晚不再显示 0，但还没有“未记录睡眠”的明确文案与引导。
- **真机样本与测试**：iOS 单元测试 runner 仍不可用（T23），本轮只有编译验证；真实 Watch/iPhone 双来源样本未测。
- **历史数据**：已经写入的 0 小时健康事件不会被自动改写；是否需要追溯标记为未知需单独迁移设计。
