# River Diary 全面重构计划（2026-09-25）

执行者：项目经理（CC）· 基线：commit `b47defd`（备份快照，含第 4 轮 UI 重构全部 WIP）
备份：`backups/river-diary-full-pre-refactor-20260925-165036.tar.gz`（76M，含 .git，可完整还原）

## 0. 基线状态

- 工具链：Xcode 27 Beta（`~/Downloads/Xcode-beta.app`，27A5252f），经 `scripts/select_xcode.sh` 选择。
- 测试基线：**194 项 XCTest 全部通过，0 失败**（12.7s）。
- 代码规模：22,585 行源码 + 4,232 行测试（macOS 主包）；另有 iOS 工程、网页原型、pipeline（本轮不动 iOS/网页/pipeline，专注 macOS 主应用）。
- 审计方式：三路并行深度审计（设计合规 / 代码质量与健壮性 / 性能与可访问性），全部结论经本机逐行核实。

## 1. 审计结论汇总

### P0 数据安全（必须修）

| 编号 | 问题 | 位置 | 严重度 |
|---|---|---|---|
| G1 | legacy 库全部 `sqlite3_bind_text(..., nil)` 以 SQLITE_STATIC 绑定 Swift 字符串临时缓冲区，`step()` 时读取 → 悬垂指针，可写入乱码或崩溃 | `AppDatabase.swift`、`AppDatabaseHistoricalImport.swift` 全部 bind_text | HIGH |
| G2 | 活动日文件解密/解码失败被静默当作空文件：保留期清理会**删除**文件，persist 会**覆盖**当日全部记录；`StateEncryption` 丢钥匙后静默铸造新钥匙放大该风险 | `ActivityStore.swift:585-653`、`StateEncryption.swift:78-80` | HIGH |
| G3 | V2 快照恢复只关闭自身连接；其余 5 个 V2Store 实例（ActivityStore/DataIngestionStore/AIAssistantStore/LocationSourceStore/MemoryLibraryStore）仍持旧 inode，恢复后写入静默丢失 | `V2Store.swift:279-312` | MED-HIGH |
| G4 | DiaryStore 多处先改内存后持久化，persist 失败无回滚（对比 `addQuickCapture` 有正确回滚） | `DiaryStore.swift:211-523` | MED |
| G5 | `clearLocalJournal` 先清内存再删盘，失败后内存/磁盘不一致；缩进错误易误读 | `DiaryStore.swift:525-557` | MED |
| G6 | AI 配置解码失败静默回退默认值，下次 didSet 又把旧配置覆盖掉 | `AIAssistantStore.swift:125-147` | MED-LOW |
| B6 | 保存查询 `try?` 吞错 | `AskRedesignView.swift:546` | MED-LOW |
| B8 | AIKeychain `persist` 目录创建失败时静默"假成功" | `AIKeychain.swift:160-165` | MED-LOW |
| B4 | legacy/V2 库 `lastError` 从未在 UI 呈现；多处 `_ = insertRawEvent` 丢弃写失败 | 多处 | MED |

### P1 性能（高收益）

| 编号 | 问题 | 位置 |
|---|---|---|
| P1.1-1.3 | `timeline`/`stats`/`review` 为计算属性，每次 body 求值重建引擎 8-13 次；日记编辑每击键触发完整会话融合引擎 ~8 次 | `TimelineWorkspaceView`、`TodayDashboardView`、`ReviewRedesignView` |
| P1.4 | `store.entry(for:)` 每次访问全量排序 entries 数组；侧栏状态栏每帧调用 | `DiaryStore.swift:142-144` |
| P3.1 | `RiverPanelSurface` 对**包括 .inline 在内**的所有面板施加双重阴影：违反设计规范且拖慢整页滚动 | `Panels.swift:22-33,56-101` |
| P4.1 | 数据库页每次刷新新建 `V2Store()`：主线程同步打开 SQLCipher + 9 表 5 索引 DDL ×2 | `DatabaseOverviewView.swift:217-252` |
| P4.2 | MemoryLibraryStore 主线程同步 N+1 查询，onAppear/每次激活/计数变化全量刷新 | `MemoryLibrary.swift:17-35` |
| P4.3 | 记忆搜索绑定 `@AppStorage`：每击键写 UserDefaults + 全量重扫，无防抖 | `MemoryRedesignView.swift:16` |
| P2.1-2.4 | 时间线 ForEach 非懒加载全量物化；`RiverPage` 未透传 lazy；数据库页全量取数再切片 | `RiverTimelineView`、`ShellComponents`、`DatabaseOverviewView` |
| P6.1-6.3 | 启动同步做快照解密/DB 打开/保留期清理（含 DB 写）；MemoryLibrary 启动即重查 | `RiverDiaryMacApp`、`DataIngestionStore`、`RiverShell` |
| P1.6/1.7/5.1 | 逐调用 DateFormatter/ISO8601 分配（8 处）；5 份重复 "yyyy-MM-dd" formatter；调色板 NSColor 每帧重解析 hex | 多处 |

### P2 设计合规

- 颜色漂移 9 处（`.secondary`/`.tertiary`/`.white` 直接做前景；`ReviewRedesignView:122` 空心情柱用 `Color.secondary`）。
- 按钮原语绕过 13 处 `.bordered*` + `EmptyStateView` 原语本身 2 处 + 5 处 ad-hoc 胶囊按钮。
- ad-hoc 空状态 10 处（应为 `EmptyStateView(showsChrome:false)` / `RiverInsetPanel`）。
- padding/spacing 字面量 ~58 处（重灾区：ShellComponents、AskRedesignView、RiverShell、ProgressWorkspaceView、InspectorPanel）；跨列对齐魔数（`InspectorPanel:586` 的 54、ProgressWorkspaceView 列宽重复推导）。
- 死文件：`SignalStyle.swift`（含违规色板，已死）、`Domain/LifeRhythm.swift`（含唯一 hex 漂移，已死）。
- 页宽魔数：Timeline 1040 / Database 820 / Ask 760（与 920/1000 体系不一致 → 收编为具名常量，不改像素）。

### P3 可访问性

- 4 处图标按钮无 accessibilityLabel（CommandPalette 清除、Ask 清除、SharedUI 清除、DateNavigator 前后一天）。
- 1 处 `.onTapGesture` 行（记忆-随笔行）键盘不可达。
- 固定行高 28/30pt 在动态字号下裁字。
- Inspector 打开无 VoiceOver 播报、焦点不迁移。
- 快记状态点仅用颜色区分（绿/灰）。

### P4 代码质量

- 死文件 4 个（~475 行）+ 死成员 ~20 个（DiaryStore 恢复草稿/关怀确认子系统、AppDatabase 4 个无引用查询 ~200 行、Panels 两个原语、MoodInsight AIDraftEngine 链等）。
- 重复逻辑：`applyIngestedData`/`applyDailyCapture` 快记去重块近似重复；日文件"分组→加密→原子写"三处重复；8 处逐调用 formatter。
- `V2Store` 无 busy_timeout（当前靠 MainActor 串行兜底，属隐患）。
- 亮点（保持）：零 TODO、零 print、零 try!/as!、@MainActor 纪律好、备份恢复路径测试充分。

## 2. 执行计划（七个波次，每波结束跑全量测试）

### Wave 1 — 数据安全（P0）
1. `AppDatabase`/`AppDatabaseHistoricalImport` 引入与 V2Store 相同的 `transientDestructor`，全部 bind_text 换用之。
2. ActivityStore：`readSessions` 返回可区分"损坏"的结果；损坏文件改为**隔离**（改名 `.corrupt`）而非删除；persist 遇不可读既有文件拒绝覆盖并报错；storageSummary 呈现隔离事件。
3. V2Store 增加实例登记表（static 弱引用集合）；`restoreEncryptedSnapshot` 换文件后让全部存活实例重开连接。
4. DiaryStore：为"先改内存后持久化"路径补回滚（对齐 `addQuickCapture` 模式）；修 `clearLocalJournal` 顺序与缩进。
5. 写失败呈现：`_ = insertRawEvent` 等丢弃点接入既有反馈通道（保底 storageSummary/lastError 日志化）；AskRedesignView 保存查询、AIKeychain persist 假成功修复。
6. AI 配置解码失败：保留旧 blob 不被 didSet 覆盖（解码失败时暂存原样并提示）。
7. 测试：unicode/长文本经 legacy 库往返；损坏日文件隔离不删；双实例恢复后写入落新文件；DiaryStore 回滚。

### Wave 2 — 性能
1. 三大页面计算属性改 body 内一次性快照（Timeline/Today/Review/Footprints/WorkLearn）。
2. DiaryStore：维护 `entries` 排序缓存 + `[String: DiaryEntry]` 索引，变更时失效。
3. `RiverPanelSurface(.inline)` 去阴影（对齐设计规范）。
4. 数据库页共享 V2Store 实例；MemoryLibrary 批量确认查询 + 延迟刷新。
5. 记忆搜索防抖 + 移除每击键 AppStorage 写入。
6. 时间线 LazyVStack；`RiverPage` 透传 lazy；数据库页 SQL LIMIT/OFFSET。
7. formatter 全部静态化（新增统一 `AppFormatters`），调色板 NSColor 缓存。
8. 启动减负：快照/清理/库刷新延后（保持行为等价）。

### Wave 3 — 设计合规
1. 删除死文件 `SignalStyle.swift`、`Domain/LifeRhythm.swift`。
2. 9 处颜色漂移改 token。
3. `EmptyStateView` 原语按钮改 CTA；13 处 `.bordered*` 迁移到按钮原语；5 处 ad-hoc 胶囊改 `FilterChip`/`linkAction`。
4. 10 处 ad-hoc 空状态迁移到 `EmptyStateView(showsChrome:false)`/`RiverInsetPanel`。
5. padding/spacing 字面量收编到 token（重灾区逐文件清零）；魔数对齐改共享常量（`TimelineRowMetrics`）；页宽魔数收编为 `AppLayout` 具名常量。
6. 3 处原生字体风格漂移改 `AppTypography`。

### Wave 4 — 可访问性
1. 4 处图标按钮补 accessibilityLabel；随笔行改 Button；快记状态点加文字。
2. 28/30pt 固定行高改 minHeight；ribbon 小时标签 minHeight。
3. Inspector 打开时 VoiceOver 播报 + 焦点迁移；装饰元素 accessibilityHidden。

### Wave 5 — 代码质量
1. 删除无引用死代码（AppDatabase 4 查询 + 孤儿 DatabaseModels、Panels 死原语、MoodInsight 死链、DiaryStore 死方法、AIAssistantStore/MemorySearch 死成员）——逐一验证引用后再删。
2. `applyIngestedData`/`applyDailyCapture` 去重；formatter 重复定义统一到 `AppFormatters`。
3. V2Store busy_timeout；PRAGMA 结果检查。

### Wave 6 — 测试补强
- 覆盖 Wave 1 全部修复；补 `saveDailyCapture` 保留标志逻辑、StateEncryption 钥匙缺失行为、DiaryStore 回滚；保持 194 项全绿并新增。

### Wave 7 — 文档与终验
- 更新 `docs/DEV_BUILD_STATUS.md`（本轮验证记录）、补根 README（指向 docs/ 结构）；`make mac` 重建 dist；全量测试 + 构建零警告核验；分波次提交。

## 3. 验收标准

1. 全量 XCTest 通过且数量 ≥ 基线 194 + 新增用例。
2. `grep` 复核：Sources 内无 `bind_text(..., nil)`、无 `.borderedProminent`/`.bordered` 按钮样式（原语内部除外）、无系统色/`.secondary` 前景漂移、无死文件。
3. `make mac` 成功产出 dist 应用。
4. 三个 P0 修复各有针对性测试证明。
5. 全部改动分波提交，可回溯；文档与实际状态一致。

## 4. 风险策略

- 不改变任何视觉像素（除规范要求去阴影的 .inline 面板）；页宽魔数收编不改数值。
- 不动 iOS 工程、网页原型、pipeline（另行安排）。
- 不改加密格式与备份格式；不引入跨设备/同步功能（P2 待外部决策）。
- 每个 Wave 结束：`swift test` 全绿才进入下一波。
