# 历史快照与网页构建管道

## 作用范围

本文件说明仍在使用的旧快照导入、聚合与网页输出。原生双端的Event/Operation事实与加密复制见 [River Node](RIVER_NODE_ARCHITECTURE.md)，当前取舍与任务以 [主规划](../../主规划.md) 为准。`data/raw.json` 是这条快照管道的原始输入，不替代原生事实库；不要直接编辑生成的 `data/data.json`。

```bash
python3 build.py
python3 -m unittest discover -s tests
```

构建会：

1. 合并 `web-preview/src/css` 与 `web-preview/src/js` 到运行用的 `web-preview/css/style.css`、`web-preview/js/app.js`。
2. 校验并清洗 `data/raw.json`。
3. 合并 macOS 每日采集导出的本地评分、HealthKit 聚合摘要与快记（`data/ios-user-data.json`）。
4. 生成 `summary`（总量、均值、健康天数）与 `data_quality`（关键缺失、待评分、缺概览、缺计划、异常阶段）。
5. 生成网页单文件 `dist/index.html`。
6. 把清洗后的数据同步到 iOS `Resources/data.json`，并尽力同步 iCloud；权限不足时构建不会失败。

实现拆分在 `pipeline/` 中；`build.py` 保留为兼容入口。详细边界见 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## macOS 每日采集

macOS 应用是采集调度器，不再依赖外部定时脚本。采集来源的完整清单与口径见 [数据源采集方案](DATA_SOURCES.md)。

1. iPhone 当前的评分、睡眠、运动和快记以加密 Event/Operation 复制到共享文件夹；明文 `river-diary-user-data.json` 已停写，只在文件存在时作为兼容基线读取。
2. macOS 在每日采集时刻读取本机来源（Chrome 今日访问、备忘录今日标题、实时足迹汇总），并把已复制的健康快照、快记和评分并入。
3. 清洗后的日记录使用 AES-GCM 加密保存到 `~/Library/Application Support/RiverDiaryMac/Ingestion/daily-capture.bin`（旧的 `health-snapshot.bin` 仅作迁移读取），同时写入 V2 的 `ingestionSnapshot` 聚合事件和旧混合库明细。
4. macOS 通过合并逻辑更新主页、足迹、健康视图和快记。
5. 从项目 `dist/River Diary.app` 运行且从未设置过导出时，采集结果会默认原子导出为明文 `data/ios-user-data.json`，供 `build.py` 使用；用户也可以在设置里更改或停止导出。

调度由每日 22:30（可改）的 60 秒 Timer 加 2 小时宽限窗口组成，应用启动时也会立即补采一次；没有后台调度器，应用退出后采集停止，需要持续采集时保持应用打开。

## 与当前原生同步的关系

当前原生双端已经使用Event/Operation/Artifact及iCloud Drive/LAN加密复制；本轮不再另立CloudKit整文件同步建设路线。这里保留的旧共享JSON读取与快照输出属于兼容能力，仍有调用时不能直接删除。删除/压缩复制对象、密钥恢复和跨版本兼容按主规划验收。

完整 `build.py` 会更新项目与可用iCloud目录；只需测试时运行管道测试和资源构建，不执行完整数据同步。是否启用旧聚合导出以用户设置和当前实现为准，不能因目录存在就视为额外授权。
