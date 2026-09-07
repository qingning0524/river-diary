# 数据管道与云端建议

## 本地优先

`data/raw.json` 是日记内容的唯一原始快照；不要直接编辑 `data/data.json`。

```bash
python3 build.py
python3 -m unittest discover -s tests
```

构建会：

1. 合并 `src/css` 与 `src/js` 到运行用的 `css/style.css`、`js/app.js`。
2. 校验并清洗 `data/raw.json`。
3. 合并 macOS 定时采集得到的本地评分与 HealthKit 聚合摘要。
4. 生成 `summary`（总量、均值、健康天数）与 `data_quality`（关键缺失、待评分、缺概览、缺计划、异常阶段）。
5. 生成网页单文件 `dist/index.html`。
6. 把清洗后的数据同步到 iOS `Resources/data.json`，并尽力同步 iCloud；权限不足时构建不会失败。

## macOS 定时采集

macOS 应用是采集调度器，不再依赖外部定时脚本：

1. iOS 把本地评分、睡眠、运动和快记写入 iCloud 的 `river-diary-user-data.json`。
2. macOS 在设置指定的频率下读取该文件，逐条校验并丢弃异常记录。
3. 清洗结果使用 AES-GCM 加密保存到 `~/Library/Application Support/RiverDiaryMac/Ingestion/health-snapshot.bin`。
4. macOS 通过合并逻辑更新主页、足迹、健康视图和快记。
5. 从项目 `dist/River Diary.app` 运行时，采集快照会自动原子写入 `data/ios-user-data.json`，供 `build.py` 使用；用户也可以在设置里更改或停止导出。

`NSBackgroundActivityScheduler` 会在 macOS 应用运行期间按系统建议安排后台工作，并在睡眠或高负载时延迟采集。应用退出后调度器随应用停止；需要持续采集时保持应用打开。

## 是否上云

建议先保持本地优先，后续如果要多设备使用，再加一个最小同步层：

- 存储：CloudKit private database 最适合个人健康/情绪数据；数据仍归用户 iCloud 账号。
- 数据形状：云端保存 `raw.json` 版本化记录，每次更新带 `generated`、`schemaVersion` 和内容 hash。
- 冲突：按天合并，不要整文件覆盖；用户本地评分和 HealthKit 聚合始终保留设备端副本。
- 隐私：云上不保存原始浏览域名和聊天对象；同步前先清洗成聚合统计。

如果只是 iOS 端自己采集和查看，不需要云；如果网页和 iOS 都要成为真实数据入口，CloudKit 是比自建服务器更合适的起点。
