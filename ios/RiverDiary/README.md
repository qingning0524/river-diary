# 情绪河流 iOS 版

这是一个原生 SwiftUI 应用，用来查看和整理「河流日记」中的每日情绪、事项、屏幕使用摘要与洞察。当前版本支持 iPhone 与 iPad。

## 打开与运行

1. 在 Xcode 中打开 `ios/RiverDiary/RiverDiary.xcodeproj`。
2. 选择一个 iPhone 模拟器或已信任的开发者设备。
3. 按常规方式 Run。首次构建已确认使用 Xcode beta 与 iOS 27 SDK 通过。

如果通过命令行构建，可使用：

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project ios/RiverDiary/RiverDiary.xcodeproj \
  -scheme RiverDiary -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ios/.build build CODE_SIGNING_ALLOWED=NO
```

`DEVELOPER_DIR` 需要指向实际安装的 Xcode beta 路径。

## 更新数据

在项目根目录更新 `data/raw.json` 后执行 `python3 build.py`。脚本会清洗数据并同步到
`RiverDiary/Resources/data.json`，两端看到同一份快照。

## 当前功能

- 今日/历史日记浏览与日期切换。
- 心情大卡点按编辑，评分会在 0–100 内校验并保存到本机。
- 情绪河流图、洞察摘要、阶段分布与日记搜索。
- HealthKit 最近 7 天睡眠汇总，包括核心睡眠、深睡、REM 与清醒时间。
- Family Controls 授权入口，为后续 Screen Time 聚合做准备。
- 详情页展示标签、活动、常用应用、常访站点、观察笔记和计划。
- 设置页支持还原本地修改过的心情评分。
- 洞察页提供最近睡眠时长与当日心情的对照。
- 洞察页提供数据体检，快速发现待评分、缺概览与缺计划的日期。

## 数据与隐私

`Resources/data.json` 是只读内容快照。用户修改的心情评分保存在本设备 `UserDefaults` 中，不会上传。

HealthKit 请求睡眠与运动数据，并按天聚合展示和同步；不保存原始样本。屏幕使用时间能力应当保持“最小聚合”原则：不要保存原始 App 记录，只保留每日汇总、分类或少量必要项目。

## 后续采集建议

- 健康与睡眠：继续使用 HealthKit，按夜晚聚合，不做逐条样本导出。
- 屏幕使用时间：新增 `DeviceActivityReport` 扩展，通过用户主动授权获取聚合结果；不能、也不应尝试抓取任意 App 明细。
- 持久化：当数据逐渐增多时，迁移到 SwiftData，睡眠与屏幕数据用独立实体保存。
- 同步：如需多设备同步，优先使用 CloudKit private database，避免把情绪与敏感统计放到第三方后端。
