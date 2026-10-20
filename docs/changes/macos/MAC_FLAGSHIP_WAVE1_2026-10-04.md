# 河流 Mac 端旗舰化 · 第一轮改造落地（2026-10-04）

上一份全面审查报告未保留在当前项目中；当前专项路线见 [Mac 重构规划](../../../主规划.md)。以下为 2026-10-04 当轮（M1 信任止损 + M2 平台手感）的交付与验证记录。

## 验证结果

- `swift build -c release`（项目 Xcode-beta 工具链）：通过
- Mac 测试（隔离环境）：**391 / 391 全绿**（其中修复了 2 个未跟上代码语义的过时测试）
- RiverDiaryCore 测试：**49 / 49 全绿**（修复了 2 个夹具无效的新测试）
- `make_app.sh` 完整打包：通过
- **真机冒烟**：打包后的 app 启动正常，密钥文件实时迁移为 `RDMKEYv2` 包装格式（69 字节），SQLCipher 库保持加密，退出正常

## 已落地（按主题）

### 1. 根密钥加固（审查 P0-1，最重的一项）
`StateEncryption.swift` 重写密钥解析：
- 密钥文件仍是主副本（保留 Time Machine 恢复能力），但**内容改用 Keychain 里的 32 字节包装密钥加密**（`kSecAttrAccessibleWhenUnlocked`，非 ThisDeviceOnly——避免"还原系统后密钥凭空消失"）。偷走文件的进程还要过 Keychain ACL 这一关。
- 旧明文密钥文件**自动迁移**为包装格式；极老安装（密钥在 Keychain）迁移链保持不变。
- 解包失败**绝不静默新建密钥**（那会让全部旧数据变成永久解不开的密文），改为显式抛错。
- 密钥解析整体串行 + 进程内缓存：消除并发首解的竞争窗口（两线程各生成密钥、内存与落盘不一致的数据损坏路径）。
- API Key 回退文件（`AISecureKeyStore`）走同一加密层，被连带加固。

### 2. 静默失败清零
- `AppLock.unlock` 的失败原因不再丢弃，锁屏上直接显示（此前用户被锁在门外无任何提示）。
- `AppDatabase.runQuery` prepare/step 失败写入 `lastError`（此前静默返回 []，表现为"数据为空"）。
- `saveDailyCapture` 新增 `collectedSessions` 守卫：修复 DataIngestionStore 在 `attach()` 之前写库把 legacy 库当天会话**整段抹掉**的数据丢失路径。
- 明文导出（含浏览记录/快记正文）完成后明确提示"明文 JSON，请妥善保管"。
- AI 错误信息不再持久化响应体片段 / 隐式保存输入中的 key ——（后两项在 P0-9，见"下轮"）。

### 3. 反馈链路
- 错误 banner **不再 3 秒自动消失**：success/info 3s、warning 8s、error 常驻待确认；错误/警告带关闭按钮。
- 展示提示时同步发 `NSAccessibility.announcementRequested` 播报（success 除外），VoiceOver 用户不再错过成败反馈。

### 4. 平台手感
- 菜单栏常驻弹层顶部补"打开河流日记 ⌘O"——关窗常驻设计下必有回路。
- **Dock 菜单**（打开/写一句/立即采集）+ **Dock 角标**实时显示习惯回顾待确认数。
- 新增"前往 → 上一天 ⌘[ / 下一天 ⌘] / 回到今天"；删除侧栏按钮上的 ⌘←/⌘→（劫持文本编辑光标移动）。
- 删除反惯例的"窗口大小"菜单（强制 center 挪窗）。
- ⌘K 双重注册、NSOpenPanel 双份实现收敛为一；导入面板改非模态 `begin`（不再 runModal 卡死全进程）。
- 命令面板：行悬停高亮、高度上限、"打开数据源…"改名"导入数据文件…"、新增"打开设置"。
- 快记窗口打开即聚焦输入框；提示文案与实际快捷键（↩）对齐。
- 破坏性操作补确认对话框：删除模型方案、退出账号。

### 5. 新功能：晚间提醒（补齐与 iOS 对齐的产品能力）
`EveningReminderStore.swift`：与 iPhone 端同口径（21:30"留给自己的话"），设置 → 隐私与备份 → 数据控制里开关；授权只在开启时申请；启动时自愈重排。此前 Mac 全工程零通知能力。

### 6. 一致性
- 统一"回顾"（侧栏 每日复盘→回顾；记忆页 周期回顾→回顾）；AI 分时段 午后→下午（与本地日报/AI 提示词一致）。
- 开发者诊断区全部统一中文（原中英混排）。
- "位置授权"行从写死的"Mac 位置采集器尚未实现"改为注入的**真实状态**（`SyncSettingsStore.locationAuthorizationProvider`），侧栏位置健康度与数据源页同一真相（此前可能一绿一灰）。
- Today 页"足迹"行从硬编码"未知"改为读取真实状态（此前位置连上也永远"未知"）。
- 记忆页嵌入的回顾卡补上 `onRevealEvidence` 回调——"引用了 N 条本机记录"chip 在记忆页里点了没反应的 bug 修复。
- 河流信"收藏"即时持久化（此前切页不保存就丢）。
- 验证码文案精简。

## 修复的过时测试（未提交改动与测试脱节，非本轮引入）

1. `UIArchitectureTests.testSettingsCategoriesHaveStableRoutes`：设置分类新增"账号与权益"后测试没更新。
2. `AnalysisInterconnectTests.testCurrentDayRebuildDetectsStaleArtifactAndQueuedCurrentFrontier`：`needsCurrentDayRebuild` 语义已改为"完成信号是正本产物而非 Job 状态"，测试按新语义重写并补全收敛路径断言。
3. `SyncCoordinatorTests.explicitConfirmationAndHabitAnswerOutrankLaterGeneratedRecords`：夹具不满足 placeCandidate 新证据门槛（缺 mapCandidates、停留 0 秒），补齐夹具。
4. `ReplicationCoreTests.placeConfirmationIsStableAndUserResolutionChangesAnalyticalState`：仍按旧判定（到访≥2次+地图名）断言，按新判定（≥2 候选+距离校验）重写。

## 本轮新发现的问题（下轮候选）

1. 【工具链】用命令行工具（CLT）直接 `swift build` 会因缺少 SwiftUIMacros/TestingMacros 插件而失败——必须经 `scripts/select_xcode.sh` 选 Xcode-beta。建议在 README/Makefile 写明，或让脚本在缺 Xcode 时给出明确报错。
2. 【中】AIAssistantStore `currentAPIKey` 优先返回**正在输入**的明文 key，且 `fetchAvailableModels`/`testConnection` 前自动 `saveAPIKey()`——未确认的 key 会被隐式持久化（P0-9 余项，本轮未动以避免破坏"先测试后保存"流程）。
3. 【低】HabitReviewView 打开页面即以 `allowManualGeneration: true` 触发评估——文档注释表明是"手动节奏=打开页面时生成"的刻意设计，但与"手动"直觉有偏差，建议改成显式"生成"按钮。
4. 【低】`Domain/LifeRhythm.swift` 全工程零引用（死代码候选）；`DiaryStore` 的 poem/averageScore/recentTrend、`MoodInsight` 的 CareAdvisor/AIDraftEngine 亦无 UI 调用方。
5. 【验证】密钥包装的 Keychain 条目在"登录前后台启动"场景不可读（WhenUnlocked），启动期 DB 打开会失败并随重试恢复——尚未观察到实际影响，列为观察项。

## 下轮建议（里程碑 M3/M4）

- **M3 性能**：启动期主线程全量 I/O（365 日文件解密、DDL、backfill）与 300s 主线程同步移后台（审查 P2-3/4/5，用户立即可感）；V2 插入路径 O(N²) 索引化（P2-1/2）。
- **M4 产品**：密码登录/忘记密码（后端已就绪，纯客户端移植，最划算）→ 附件/照片 → 当天画布渲染分享。
