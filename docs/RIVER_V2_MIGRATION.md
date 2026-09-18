# RIVER V2 迁移策略（草案，未执行）

更新：2026-09-19。本文档只描述迁移策略，**不执行任何迁移**。

## 1. 旧库（river-diary.db）哪张表可重建 / 哪张需平移

| 旧数据 | 是否可重建 | 处理 |
|---|---|---|
| `activity_sessions`（采集时段） | 是（从系统事件/`.activity` 重算） | 模板化导入，保留期间映射 |
| `daily_records` / `mood_scores` / `sleep_nights` / `exercise_days` | 是（从 iOS 健康快照重算） | 模板化导入，保留日期 |
| `chrome_visits` / `daily_notes` | 可重建来源，但标题/URL 属敏感值 | 平移但单独加密 |
| `ingestion.daily-capture.bin` / `health-snapshot.bin` | 原始快照 | 平移为 raw_events（healthSnapshot/ingestionSnapshot） |
| `state/*`：日记原文、快记、月度信 | **用户手写内容，不可重建** | 必须平移，禁止删除 |
| `DiaryStore` 的 entries/overrides/quickCaptures | **用户内容为主** | 平移（正文进自有表，机器观察进 fact layer） |

## 2. 是否破坏性
- 阶段 A（当前，已完成）：新建独立 `river-v2.db`，只建表与索引。**不影响旧库、不影响现有 UI。**
- 阶段 B（待执行）：把采集器写入 raw_events 的同时**继续写 `.activity`**（兼容红线，绝不让用户数据消失）。
- 阶段 C（待执行）：UI 读取切到 V2 便利聚合后，旧 `.activity` 写入才可停；旧文件仍然只读保留。

## 3. 保留期策略
- raw_events（证据）默认保留最长周期，独立配置，**默认 ≥ memories 引用期**，避免删掉未来重建记忆所需证据。
- 衍生表（activities/episodes/memories）可随时 `DROP → 重建`，不影响 raw_events 与用户文字。
- 敏感列（Chrome URL、窗口标题、Notes 标题、AI 正文）：入库前分类为 sensitive/user-content，按 `V2_ARCHITECTURE §5` 单独加密。

## 4. 回滚方案
- 迁移前保留旧库副本（文件名 `river-diary.db` 原样，另存 `river-diary-v2-migration-backup-<时间戳>.db`）。
- 每次切换只换“读取”或“写入”一端，不两端同时改，双读兼容窗期间保留旧路径兜底。
- V2 文件独立，`rm river-v2.db` 不影响旧库；回滚=切回旧读取路径。

## 5. 未经确认不执行
- 此文档为 Step 7 产物。任何实际迁移执行都需要单独确认，且不得删除用户真实文字副本。
