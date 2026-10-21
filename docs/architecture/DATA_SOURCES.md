# 数据源采集方案（当前实现）

更新日期：2026-10-20。本文只描述当前代码实际在采什么、何时采、采到哪里、什么条件下不采。产品取舍与未完成任务以 [主规划](../../主规划.md) 为准；跨端复制协议见 [River Node](RIVER_NODE_ARCHITECTURE.md)；旧的网页快照管道见 [数据管道](DATA_PIPELINE.md)。

## 1. 采集原则

1. **本机优先**：每个来源先写入本机（Event 追加或本地文件），再谈投影、复制和 AI；断网不阻断采集。
2. **观察、决定、推导分开**：Event 保存原始证据（系统观察或用户原话）；手写、评分、确认的状态是 Operation；AI 解释是 Artifact。采集器不写解释。
3. **缺失不补零**：来源状态区分「不支持 / 未知 / 未授权 / 无样本 / 正常 / 陈旧 / 失败」；没有样本不等于 0，读不到不等于没发生。
4. **来源只是证据**：前台应用只证明观测到应用活动，窗口标题只证明标题，照片只证明画面，运动类型不能推断出行目的。
5. **先绑定再采集**：未登录/未绑定资料时不创建正式库、不启动采集；退出登录立即停止采集、外发和后台排定。
6. **双端各自采集**：iPhone 与 Mac 是独立节点，通过加密事件对象汇聚，不共享一套明文数据库。

## 2. 链路总览

```text
iPhone                                      Mac
  HealthKit                                 实时足迹（事件驱动 + 25s 标题）
  CoreLocation（到访/显著位置/高精度）        Chrome 历史（今日）
  CoreMotion（36h 回补 + 实时）              Apple Notes 正文（今日）
  Photos + Vision（本机标签）                实时足迹汇总（分钟/Top 应用）
  Shortcuts（应用开关自动化）                地点（手动连接）
  手写/评分/快记/确认                        旧 iOS 明文 JSON（兼容基线）
        │                                          │
        ▼                                          ▼
  river-node.sqlite                        每日混合采集（默认 22:30）
        │                                          │
        └──── 加密事件对象（iCloud Drive + LAN）───►│
                                                   ▼
                                            ├→ daily-capture.bin（AES-GCM）
                                            ├→ V2 ingestionSnapshot（仅聚合指标）
                                            ├→ 旧 SQLCipher 混合库（明细）
                                            └→ 可选明文导出 → build.py（旧网页）
```

## 3. 来源总表

| 来源 | 端 | 默认 | 触发/频率 | 实际读取范围 | 主要落点 | 前提 |
|---|---|---|---|---|---|---|
| 实时足迹（应用活动） | Mac | 关 | 事件驱动：应用切换/退出、睡眠、锁屏、会话切换 | 应用名、bundleID、片段起止 | `Activity/*.activity` + RawEvent `systemApp/appForeground` | 用户手动开始记录 |
| 窗口标题 | Mac | 关 | 片段进行中每 25s 重采样；连续 50s 一致才切段 | 当前前台窗口标题 | 同上（片段字段 + 事件 payload） | 辅助功能权限 |
| 浏览器历史 | Mac | 开 | 每日采集一次 | 今日 `http(s)` 访问，最多 1000 条；Safari + Chrome/Arc/Edge/Brave 的多配置 | 每日记录 + 旧混合库 `chrome_visits.browser` | 完全磁盘访问；能读各浏览器 History |
| Apple Notes | Mac | 开 | 每日采集一次 | 今日修改的笔记标题与正文（单条 ≤20,000 字），最多 50 条 | 每日记录 + 旧混合库 `daily_notes.body` | 完全磁盘访问；能读 `NoteStore.sqlite` |
| Markdown 文件夹 | Mac | 关 | 每日采集一次 | 今日修改的 `.md` / `.markdown` / `.txt`，最多 50 个，单条 4,000 字 | 每日记录 + 旧混合库 `daily_notes.source` | 用户选择文件夹；UTF-8 |
| Kindle 划线 | Mac | 关 | 每日采集一次 | 今天 `Added on` 的划线/笔记，最多 50 条，单条 2,000 字 | 每日记录 + `daily_notes.source=Kindle` | 用户选择 `My Clippings.txt` |
| 本地 Git 提交 | Mac | 关 | 每日采集一次 | 开发目录下最多 30 个仓库、向下 3 层；今天提交数，不读 commit message | V2 Event `git/gitCommitDaily` + 每日记录 `gitCommitCount` | 用户选择目录；本机 `/usr/bin/git` |
| 屏幕时间汇总 | Mac | 开 | 每日采集一次 | 今日活跃片段分钟数、前 5 应用、专注分钟与段数 | 每日记录 `screenTimeMinutes` / `screenTopApps` / `focusMinutes` / `focusBlocks` | 实时足迹当天有片段 |
| 地点足迹 | Mac | 关 | 手动「连接位置」后持续；60s 且 100m 节流 | 坐标、精度、逆地理名称 | RawEvent `location/locationUpdate` + 地点投影 | 系统定位授权 |
| 日历与提醒事项 | Mac | 关 | 每日采集一次 | 今日日程标题/起止/参与人数/日历名；今日完成提醒标题/列表名 | V2 Event `calendar/calendarEvent`、`reminders/reminderCompleted` | EventKit 完整访问授权 |
| 天气 | Mac | 关 | 每日采集一次 | 当天天气、最高/最低温、降水；需要最近 24h 内的坐标 | V2 Event `weather/weatherDaily` + 每日记录 `weatherSummary` | 位置事件 + 网络 |
| 旧 iOS 明文快照 | Mac | 兼容 | 启动时与每日采集时，文件存在才读 | 评分/睡眠/运动/快记（`river-diary-user-data.json`） | 作为低优先级基线并入每日记录 | 文件存在且可解析 |
| 旧版日记 `data.json` | 双端 | 兼容 | iOS 启动/前台读取；Mac 手动连接后重读 | 历史日记条目、评分、生成时间 | iOS 迁移为 `journalEntry` 操作；Mac 作为只读基础快照 | 共享目录或本机文件可读 |
| Apple 健康 | iOS | 未连接 | 前台回到活跃、手动刷新、每日 22:00 后台（系统尽力） | 睡眠近 7 天（≤800 样本）；运动近 8 天日汇总 + 近 2 天 15 分钟区间；体能训练近 7 天（≤100 次）；State of Mind 近 7 天（iOS 18+） | Event `healthkit/health.sleep.snapshot`、`health.exercise.snapshot`、`health.exercise.interval`、`health.workout`、`health.stateOfMind` | 健康读授权；State of Mind 需 iOS 18+ |
| 位置与到访 | iOS | 关 | 开启后系统投递到访与显著位置变化；高精度样本手动触发（20s 超时） | 坐标、到访、精度、地点候选 | Event `core_location/location.*`、`mapkit/location.placeCandidate` | 定位授权；后台需「始终」 |
| 运动识别 | iOS | 关 | 开启时回补 36h，随后实时更新 | 步行/跑步/骑行/驾车、置信度 | Event `core_motion/mobility.activity` | 运动与健身权限 |
| 照片线索 | iOS | 关 | 开启时、回到前台时 | 最近 7 天最多 160 张，本机 Vision 场景标签 | Event `photos_vision/media.photoObservation` | 照片读权限；原图不入库 |
| 应用开关（快捷指令） | iOS | 用户自建 | 用户创建的「打开/关闭 App」个人自动化 | 应用名、bundleID、opened/closed | Event `shortcuts/app.opened`、`app.closed` | 用户在快捷指令中配置 |
| 语音速记（快捷指令） | iOS | 用户自建 | 用户用「听写文本」后调用「记录语音速记」 | 转写文本，≤20,000 字；不保存音频 | Event `shortcuts/manual.voiceMemo` | 快捷指令；已登录 |
| 手写日记/评分/快记/确认 | 双端 | 可用 | 用户主动 | 文本、0–100 评分、待确认决定 | Event + State Operation | 已绑定账号 |
| 屏幕使用时间（快捷指令） | iOS | 用户自建 | 用户创建的定时或手动快捷指令 | 当天总分钟数 0–1440 | Event `shortcuts/screenTime.daily` | 快捷指令；已登录 |

## 4. 采集器明细

### 4.1 Mac 实时足迹

- 事件驱动，不做固定轮询：监听应用激活/退出、系统睡眠/唤醒、屏幕休眠/唤醒、会话切换；关闭上一段并保存后开新段。
- 默认不开启，需用户在「设置 → 自动记录」里点「开始记录」；偏好写入 `activity.enabled`。
- 窗口标题默认关闭。开启后要求辅助功能权限；片段进行中每 25 秒重读一次，连续两次（50 秒）读到同一新标题才切段，避免通知角标抖动把一段阅读切碎。
- 支持「按时段暂停记录」，默认窗口 22:00–07:00 但默认关闭；暂停期间不新开片段。
- 片段写入 AES-GCM 加密的按日文件，同时镜像为 V2 `appForeground` 事件（标题仅在开启标题采集时进入事件）。
- 原始片段按前台应用保存；时间线读取时会过滤系统级/不可记录项，因此时间线里会出现空档，不代表那段时间没有片段。
- 关窗只是隐藏，应用常驻菜单栏继续记录；只有真正退出或退出登录才停止。

### 4.2 Mac 每日混合采集

默认 22:30（可改），默认开启，四个来源开关默认全开：

1. 读取旧 iOS 明文快照（如果存在），清洗后作为兼容基线。
2. 用 V2 中已复制的加密事件覆盖基线：`healthkit` / `legacy-icloud` 的睡眠与运动快照按本地日聚合，`quickCapture` / `manual.note` 变快记，`mood:*` State Operation 变评分。
3. 后台读取浏览器今日访问：Safari + Chrome/Arc/Edge/Brave 多配置，最多 1000 条，排除非 `http(s)`。
4. 后台读取 Apple Notes 今日修改的标题与正文（最多 50 条；正文来自 `ZICNOTEDATA.ZDATA` 的 gzip protobuf，单条截断到 20,000 字）。
4b. 若开启「Markdown 文件夹」，扫描今天修改的 Markdown/TXT，最多 50 个、单条 4,000 字；跳过 `.obsidian`、`.git` 等目录。
4c. 若开启「Kindle 划线」，读取 `My Clippings.txt` 中今天 `Added on` 的划线/笔记，最多 50 条、单条 2,000 字；日期无法解析的条目跳过。
5. 从实时足迹取今日屏幕分钟数、Top 5 应用，以及按连续片段推导的专注分钟/段数。
5b. 若开启「日历与提醒事项」，读取今日日程与完成提醒，写入 V2 的 `calendar/calendarEvent`、`reminders/reminderCompleted`。
5c. 若开启「天气」，用最近 24 小时内的位置查询 Open-Meteo，写入 `weather/weatherDaily` 和每日记录 `weatherSummary`；没有位置时不猜城市。
6. 组装 `DailyCaptureRecord`，AES-GCM 写入 `~/Library/Application Support/RiverDiaryMac/Ingestion/daily-capture.bin`。
7. 写一条 V2 `ingestion/ingestionSnapshot`（只含步数、距离、能量、睡眠时长、屏幕分钟等聚合指标，不含 URL/标题/正文）。
8. 写入旧 SQLCipher 混合库：每日汇总、评分、睡眠、运动、Chrome 明细、Notes 标题与正文、快记。
9. 若配置了导出位置，写明文 JSON（见 §6）。
10. 采集完成后按需运行自动 AI 整理。

`Chrome` 与 `Notes` 的明细只存在 Mac 本机旧库与明文导出里，**不进入加密事件复制**；V2 只拿到聚合指标。日历、提醒事项与体能训练走 V2 事件复制，因此会跨端出现。

### 4.3 Mac 地点

- 默认不连接，需在设置里主动「连接位置」；启动不自动恢复连接。
- 精度 `kCLLocationAccuracyHundredMeters`，距离过滤 100m；写入前再按「60 秒内且位移 <100m 丢弃」节流。
- 无效精度（`horizontalAccuracy < 0`）与超过 5 分钟的缓存定位不写入。
- 逆地理只用于补充名称；迟到或失败的 geocode 不覆盖已有名字。

### 4.4 iOS Apple 健康

- 只有用户点过「连接 Apple 健康」后才读取；`isAuthorized` 只是「授权流程成功结束」的本地标记（用于是否继续读取的门禁），HealthKit 读权限本身无法查询，因此来源状态评估传入 `nil`，不把「已请求」当成「每种类型都可读」。
- 睡眠：近 7 天、最多 800 条样本，先映射为平台无关区间，再交给 Core 聚合：多来源重叠取并集、Apple Watch 优先于 iPhone、再优先于第三方/手动；「未分期」计入总睡眠；只有清醒/在床记录的夜晚标为未知而不是 0。
- 运动：步数、步行/跑步距离、活动能量；近 8 天按日汇总，另取近 2 天 15 分钟区间用于当天趋势。
- 每次快照变化都写入 `health.sleep.snapshot` / `health.exercise.snapshot` / `health.exercise.interval` 事件；写入按稳定键去重，避免同一晚重复。同步状态随后标为「等待加密同步和核对」，真正同步由前台 120 秒检查、回到活跃或后台任务触发。
- State of Mind（iOS 18+）：近 7 天 ≤100 条，写入 `health.stateOfMind`；效价夹紧到 -1…1，类型的「此刻情绪 / 今日心情」写入事件文本。iOS 17 设备直接跳过，不把它标成失败。
- 归属口径版本化（当前 v1：醒来日归属；白天 ≤3h 记午睡），并记录观测时区。

### 4.5 iOS 位置

- 默认关闭；开启后先请求「始终」授权，用 `startMonitoringVisits` + `startMonitoringSignificantLocationChanges`，低功耗、由系统投递，App 被终止后仍可收到（需 Always）。
- 只在使用期间授权时，后台到访不会到达，设置里会明确提示。
- 「记录一次当前位置」是手动高精度采样：`kCLLocationAccuracyBest`，20 秒超时，要求精确位置；结果先写事件，再异步解析地点候选。
- 地点候选来自 MapKit/CLGeocoder；解析失败只记录失败原因，坐标仍保留，稍后重试。
- 所有写入都要求「已启用 + 会话活跃」，退出登录后回调被生成号守卫丢弃。

### 4.6 iOS 运动识别

- 默认关闭；开启后先回补最近 36 小时，再订阅实时活动更新。
- 只保存活动类型与置信度，不推断通勤方式；信息不足时 UI 显示「乘车」或「骑行」，不猜测网约车/共享单车。
- 同一分钟内的活动按稳定键去重。

### 4.7 iOS 照片

- 默认关闭；开启时请求照片权限，只读最近 7 天、最多 160 张。
- Vision 在本机生成场景/食物等标签与摘要，原图与相册标识不写入数据库，只存哈希令牌与标签。
- 若同时开启「允许当前 AI 看最近照片」，日终分析最多把 4 张小尺寸图发给用户配置的模型；照片不经过账号服务器。

### 4.8 iOS 快捷指令

- 系统不提供 iOS 前台应用自动采集，应用开关只能由用户在快捷指令里创建「打开 App / 关闭 App」个人自动化，动作为 River Diary 的「记录应用活动」。
- 支持填写显示名、bundleID 与 opened/closed；事件先写本机。
- 未登录且没有既有资料库时，Intent 直接报错，不会替用户建库。

### 4.9 手动记录

- 手写日记、快记、0–100 评分、待确认回答、习惯/记忆决定：双端都可主动写入。
- 这些是用户陈述/决定，优先级高于 AI 解释；删除以 tombstone 传播。

### 4.10 未接入与兼容路径

- **iOS 屏幕使用时间的系统 API**：`ScreenTimeStore` 仍然只有授权封装，没有实例化和采集调用；App 不申请 Family Controls/DeviceActivity entitlement。当前采用下方 4.12 的快捷指令方案，不是系统级自动采集。
- **旧明文快照**：`river-diary-user-data.json` 当前代码中没有写入者，只有 iOS 的迁移导入和 Mac 的兼容读取；iPhone 的新数据一律走加密事件。
- **旧版日记快照**：`data.json` 是历史网页管道的产物；iOS 在获得共享文件夹授权后读取并迁移为 `journalEntry`，Mac 在设置里手动连接后作为主页/足迹的只读基础快照，不参与实时采集。
- **旧网页快照**：`data/raw.json → data/data.json → dist/index.html` 是历史内容管道，不属于实时采集。

### 4.11 日历与提醒事项（Mac）

- 默认关闭；用户在「设置 → 自动记录 → 日历与提醒事项」打开后才请求 EventKit 完整访问。
- 只读：日程标题、起止、是否全天、参与人数、日历名；完成提醒的标题、列表名、完成时间。**不读备注、附件、地点和参与者姓名。**
- 写入 V2 事件 `calendar/calendarEvent` 与 `reminders/reminderCompleted`，ID 由 EventKit 标识和时间派生，同日重复采集不会重复。
- 未授权或读取失败会显示在设置行里，不会把空结果当作“今天没有安排”。

### 4.12 屏幕使用时间（iOS 快捷指令）

- iOS 不向第三方 App 开放屏幕使用时间原始数据，Shortcuts 也没有读取它的系统动作；当前方案是用户主动输入。
- 新增 App Intent「记录屏幕使用时间」：参数为 0–1440 分钟，写入 `shortcuts/screenTime.daily` 事件（`metrics.screenMinutes`）。
- 设置页提供「打开快捷指令」与配置步骤：每天 22:00 的「特定时间」自动化 → 「要求输入」数字 → 「记录屏幕使用时间」。
- 同一天多次运行以最新一条为准，不相加；设置页显示今天已记录的分钟数。
- 这是用户陈述，不是系统观测；AI 和 UI 不能把它当成精确的设备使用时长。

### 4.13 体能训练（iOS 健康）

- 沿用 HealthKit 授权，新增 `HKObjectType.workoutType()` 读权限；不需要新的权限弹窗类型。
- 近 7 天最多 100 次训练，保存类型、起止、时长、距离和活动能量，写入 `healthkit/health.workout`。
- 类型只做常见运动的名称映射；未知类型标为「其他运动」，不猜测具体项目。

### 4.14 天气（Mac，默认关闭）

- 只使用最近 24 小时内带坐标的 V2 事件（本机地点或复制过来的 iPhone 位置）；找不到坐标时显示“没有可用位置”，不按城市名猜。
- 通过 Open-Meteo 查询当天天气代码、最高/最低温、降水量；结果缓存 6 小时，同一天同一坐标不会重复请求。
- 写入 `weather/weatherDaily` 事件，并附到每日记录 `weatherSummary`；它只是氛围上下文，不参与“今天做了什么”的事实判断。

### 4.15 空闲与专注（Mac）

- 每 30 秒读取系统 HID 空闲时间；超过 5 分钟没有键盘/鼠标输入，就在最后一次输入的时刻关闭当前片段，恢复输入后开新片段。不读按键内容，也不需要输入监控权限。
- 屏幕时间因此是“活跃片段”，不是“前台窗口挂着的时间”。
- 专注段由 `FocusCalculator` 从片段推导：只算工作/学习/创作类；相邻片段间隔 ≤5 分钟算同一次；短暂切到沟通/浏览（<5 分钟）不打断；累计 ≥25 分钟才成立。
- 专注是启发式指标，不是用户声明的“我在专注”；每日记录会同时保留片段数和分钟数。

### 4.16 Markdown 文件夹（Mac，默认关闭）

- 用户主动选一个文件夹（Obsidian / Logseq / Bear 导出等）；只读今天修改的 `.md` / `.markdown` / `.txt`。
- 优先 frontmatter 的 `title:`，其次第一个一级标题，最后用文件名；正文去掉 frontmatter 后最多保留 4,000 字。
- 最多 50 个文件；跳过 `.obsidian`、`.git`、`node_modules` 等目录。
- 不监听、不常驻；每次每日采集扫一遍。文件夹不存在或文件不是 UTF-8 时显示原因，不当作“今天没写”。
- 与备忘录共用 `daily_notes` 表和每日记录，`source` 列区分“备忘录 / Markdown”。

### 4.17 Kindle 划线（Mac，默认关闭）

- 用户选择 `My Clippings.txt`；只读今天 `Added on` 的 Highlight / Note / Bookmark。
- 日期用 `NSDataDetector` 解析，避免为每种 Kindle 语言手写日期格式；无法解析日期的条目跳过，不按文件修改时间硬塞到今天。
- 书名去掉末尾 `(作者)`；正文最多 2,000 字、最多 50 条；与备忘录/Markdown 共用 `daily_notes`，`source=Kindle`。
- 文件不存在或不是文本时显示原因；没有今天条目不算错误。

### 4.18 心理状态（iOS 18+）

- 沿用 HealthKit 授权；只在 iOS 18+ 请求 `HKObjectType.stateOfMindType()`，iOS 17 直接跳过。
- 近 7 天最多 100 条，写入 `health.stateOfMind`，包含效价和「此刻情绪 / 今日心情」。
- 效价先经 `StateOfMindReading.normalizedValence` 夹紧到 -1…1；非有限值按中性 0 处理。
- 它和日记自己的 0–100 评分不是同一口径，展示时必须标来源，不能直接相加或平均。

### 4.19 本地 Git 提交（Mac，默认关闭）

- 用户选择一个开发目录；向下最多 3 层，最多 30 个仓库，跳过 `node_modules`、`.build`、`DerivedData` 等目录。
- 对每个仓库执行本机 `git log --since=今天 --until=明天 --pretty=format:%ct`，只统计提交数量。
- 只写仓库名和提交数，不读 commit message、作者邮箱、diff；不调用任何托管平台 API。
- 写入 V2 `git/gitCommitDaily` 和每日记录 `gitCommitCount` / `gitRepositories`；无法读取的仓库会汇总成状态。
- Git 是开发者向来源，默认关闭；不适用于非开发者。

### 4.20 语音速记（iOS，快捷指令）

- 不直接申请麦克风/语音识别权限；用户用快捷指令的「听写文本」得到文字，再调用 App Intent「记录语音速记」。
- 只保存转写文本（`shortcuts/manual.voiceMemo`），最多 20,000 字；不保存音频，也不上传音频。
- 空文本直接报错；设置页有配置说明与打开快捷指令入口。
- 局限：转写质量由系统听写决定；它是一条手动输入，不是后台录音。

### 4.21 设备日上下文（Mac + iOS）

- 每台设备每天发布一份 `DayContextSnapshot`，作为跨端投影：只含摘要、标题、计数和短摘录，不是新的事实库。
- Mac 在每日采集结束时发布；iPhone 在健康快照/屏幕时间/语音速记写入后发布，没有来源时不发布。
- 事件：Mac `dayContext/dayContextSnapshot`，iPhone `day_context/dayContextSnapshot`；payload 的 `contextJSON` 走现有加密复制，`text` 存摘要供搜索。
- 打开 Mac 逐来源全文同步后，另写 `urlVisit` / `noteModified` 独立证据 Event（浏览 ≤500/天）；手机时间线仍只读 DayContext，避免重复刷屏。
- 双端今日页显示“其他设备的一天”，时间线显示设备上下文行；网页 mirror v2 把快照放进 `contexts` 并映射成 `kind=context` 卡片。
- 只复制“最小充分上下文”：默认不复制完整 URL 列表、笔记全文、照片、健康原始样本、commit message；用户打开逐来源全文同步后，才会另写独立证据事件并扩展 DayContext。详见 [MEMORYOS_CROSS_DEVICE_CONTEXT](MEMORYOS_CROSS_DEVICE_CONTEXT.md)。

## 5. 调度与时序

### Mac

| 时机 | 行为 |
|---|---|
| 登录后进入主界面 | `ingestion.start()`：重排定时器并立即采一次当天；实时足迹按偏好恢复 |
| 每日 22:30（可改） | 采集 + 自动 AI 整理 |
| 每 60s tick | 仅在「已过采集时刻且距今 ≤2h、今天未采过」时补采；已采但 AI 未跑则补跑 AI |
| 应用切换/睡眠/锁屏/会话变化 | 关闭当前片段并保存，必要时开新片段 |
| 片段进行中每 25s | 重读窗口标题（仅开启标题采集且已授权） |
| 每 60s | 检查是否进入/离开暂停时段 |
| 每 30s | 检查 HID 空闲；超过 5 分钟关闭当前片段，恢复输入后重开 |
| 每 300s | 账号服务活跃时做一次同步核对 |
| 退出登录 | 停采集、停位置、停 LAN、关 AI 门禁、关数据库、撤销晚间提醒 |
| 应用退出 | 停定时器；关窗不退出，继续常驻记录 |

注意：Mac 没有 `NSBackgroundActivityScheduler`；采集依赖应用进程存活。启动时会立即补采一次，但错过 22:30 后只有 2 小时宽限窗口，超时则等下次启动或次日。

### iPhone

| 时机 | 行为 |
|---|---|
| 启动/回到前台 | 若已登录：开库、恢复 LAN、启动运动（若开）、刷新照片、同步；健康已连接则读一次 |
| 前台每 120s | 检查 AI 自动任务并同步 |
| 写入日记/评分/快记/确认后 | 部分路径立即触发同步，其余等 120s 检查 |
| 进入后台 | 停 LAN；已登录则排定 22:00 健康后台刷新 |
| 22:00 后台刷新（系统尽力） | 读健康 → 写事件 → 同步 → 重排下一次 |
| 退出登录 | 停 LAN、运动、位置、后台任务；AI/同步门禁关闭 |
| 位置事件 | 由系统在到访/显著变化时投递；手动高精度样本 20s 超时 |

`BGAppRefreshTask` 只保证「最早 22:00」，实际执行由系统决定，可能延后或不执行；不能当作固定定时采集。

## 6. 落盘、加密与外发边界

| 数据 | 位置 | 保护 | 是否跨端 |
|---|---|---|---|
| iPhone Event / Operation / Artifact | `Application Support/RiverDiary/Database/river-node.sqlite` | 系统文件保护（`completeUntilFirstUserAuthentication`）；非 SQLCipher | 是，经加密对象 |
| iPhone 本地备份 | 用户导出 | AES-GCM，含事件/操作/Artifact，不含密钥 | 手动 |
| Mac V2 事实库 | `river-v2.db` | SQLCipher | 是，经加密对象 |
| Mac 实时足迹 | `Application Support/RiverDiaryMac/Activity/<日>.activity` | AES-GCM（钥匙串包装密钥） | 事件镜像会复制 |
| Mac 每日采集结果 | `.../Ingestion/daily-capture.bin` | AES-GCM | 否（仅本机） |
| Mac 旧混合库 | 旧 SQLCipher 库 | SQLCipher | 否 |
| Mac 明文导出 | `data/ios-user-data.json` | **明文**，含浏览 URL、页面标题、快记正文 | 否 |
| 旧网页产物 | `data/data.json`、`dist/index.html` | 明文 | 否 |
| 账号服务器 | PostgreSQL | 身份、会话、设备、权益；默认不收日记/健康/位置正文；可选云空间只存端到端加密密文 | 仅密文 |
| AI 外发 | 用户配置的模型端点 | 按用户开关决定是否包含健康与照片观察；不经过账号服务器 | 用户主动 |

从项目 `dist/River Diary.app` 运行、且用户从未设置过导出时，若检测到项目 `data/` 目录，会默认把每日记录导出为明文 `data/ios-user-data.json`；导出可改路径或停止，导出提示会明确说明含浏览记录与快记正文。

## 7. 来源状态

Core 的 `HealthSourceStatus` 区分七态：

- `unsupported`：设备/系统不支持；
- `unknown`：无法确认权限或状态；
- `notAuthorized`：确认未授权；
- `noSamples`：确认可用但还没有样本（不是 0）；
- `healthy`：有样本且未超过 36 小时；
- `stale`：有样本但最近一次超过 36 小时；
- `failed`：最近一次读取有真实错误，优先于授权状态。

Mac 数据源页把它压缩成「正常 / 采集中 / 未知 / 已暂停 / 有问题」五种展示状态，并分别显示项目管道、实时足迹、健康快照、地点四项。

iOS 侧虽然 `HealthKitStore.sourceStatus` 已实现，但当前没有界面使用它；记录来源页仍以「已连接/读取到 N 晚」为主，属于待补的界面接线。

## 8. 生命周期与权限门禁

- 未登录/未绑定：不打开正式库，不启动采集；iOS 后台健康刷新要求已登录，Shortcuts 在无既有库时拒绝建库。退出登录后 iOS 仍持有已打开的数据库，Shortcuts 写入既有库的边界尚未关闭（T04 待办）。
- 退出登录：Mac 停采集、位置、LAN、AI、关库；iOS 停 LAN、运动、位置、后台任务。已发出的请求不可撤回，但迟到响应被 generation 隔离。
- 保留期：Mac 设置里的 90/180/365 天只清理旧混合采集库（日记录、健康、浏览、片段、快记、AI 结果）；V2 事实、实时足迹文件、iPhone 数据库不在此期限内，尚无统一跨库保留策略。
- 关闭某个来源不会删除历史；旧混合库在本次没采到字段时会保留当天已有值，避免开关切换把已采数据抹掉。

## 9. 已知缺口与风险

按影响排序（不是官方优先级）：

1. **读取失败只到设置状态**：浏览器历史与备忘录已能区分“没有数据”和“读不到”，但原因只显示在设置行的状态里；Mac 数据源页仍只有项目管道、实时足迹、健康、地点四行，没有每个来源的独立状态与完全磁盘访问引导。
2. **旧文档曾与实现不一致**：`DATA_PIPELINE.md` 原文写「iOS 写入明文 JSON」「NSBackgroundActivityScheduler」，与当前代码不符；2026-10-20 已按实现修正，后续仍需随采集改动同步。
3. **iOS 七态来源状态未上界面**：`sourceStatus` 已实现但无调用点，用户看不到「未知/陈旧/失败」。
4. **iOS 后台健康刷新无保证**：只有一个 22:00 的 `BGAppRefreshTask`，系统可延迟或跳过；缺真机长期证据。
5. **明文导出默认开启**：从项目 `dist` 运行时自动导出含 URL、标题、备忘录与快记正文的 JSON，只在 UI 文案提示，没有首次确认。
6. **浏览器覆盖仍有限**：已接 Safari/Chrome/Arc/Edge/Brave 的多配置，但不含无痕、Firefox、书签/下载，也不读 Safari 的 iCloud 标签页。
7. **备忘录正文解析依赖私有 schema**：`ZICNOTEDATA.ZDATA` 的 gzip protobuf 不是公开 API；schema 变化时会显示「无法解析」而不是空正文，需要随系统更新回归。
8. **Mac 地点不持久化连接**：重启后需重新点「连接位置」；也没有 iOS 那种到访/显著位置变化的低功耗模式。
9. **Mac 采集依赖进程存活**：没有后台调度器；22:30 后 2 小时宽限错过就等下次启动。
10. **保留策略分散**：旧混合库、V2、实时足迹、iOS 库各自独立，删除/撤权跨端传播仍待验收。
11. **照片窗口短**：只 7 天/160 张，AI 每天最多 4 张；历史照片不会回补。
12. **Shortcuts 全靠用户手工配置**：iOS 没有自动的前台应用采集，覆盖面取决于用户建了多少自动化。
13. **陈旧阈值固定 36 小时**：不同来源（睡眠 vs 步数）没有分别设定。
14. **采集器级自动化测试不足**：已有 `WindowTitleSampling`、备忘录 gzip/protobuf、Safari/Chromium fixture、Markdown 解析、日历事件映射与账号采集生命周期测试；HealthKit 聚合和真实后台投递仍缺 fixture 与真机证据。
15. **快捷指令屏幕时间仍是手动输入**：Shortcuts 拿不到系统屏幕使用时间，只能由用户或自动化输入总分钟数；它不是自动采集，不能对外声称精确。
16. **日历只读标题与参与人数**：不读备注、地点和参与者姓名；需要“和谁在一起”时只能依赖用户陈述或 JournalingSuggestions（本项目未采用）。
17. **天气依赖位置与网络**：没有最近 24 小时坐标就不采；Open-Meteo 不可达时当天没有天气，不补历史。
18. **专注是启发式**：25 分钟门槛、5 分钟打断容忍和“工作/学习/创作”分类都可能误判；它适合趋势，不适合逐分钟考勤。
19. **Markdown 只扫今天、最多 50 个**：不做全库索引，也不解析双链/附件；iCloud 未下载的文件会读不到，状态里会说明。
20. **Safari 历史依赖 schema**：`history_visits.title` 是较新版本才有；旧库会退回空标题。复制数据库时可能漏掉尚未合并的 WAL 记录。
21. **Kindle 日期解析依赖系统检测器**：无法解析 `Added on` 的条目会被跳过；同一划线重复导入按书名+正文+时间去重。
22. **State of Mind 只在 iOS 18+ 可用**：iOS 17 设备没有这个来源，不能显示成“零条心情”。
23. **Git 统计只看提交数**：不区分作者、分支、merge/revert，也不代表实际工作时长；多仓库可能重复计入 fork。
24. **语音速记只有文字**：不保存音频，也不提供回听；转写质量与语言取决于系统听写。

## 10. 建议的整理动作

1. 以本文作为唯一来源清单；后续来源增减先改这里，再改 `DATA_PIPELINE` 与主规划。
2. Chrome/Notes 已能区分缺失、未授权和解析失败；下一步把原因显示到数据源页，并补完全磁盘访问引导。
3. 把 iOS 七态来源状态接到「记录来源」页，至少覆盖健康、位置、运动、照片。
4. 明文导出改为首次确认 + 明确列出包含的字段；或默认写入加密容器，仅在用户显式导出时解密。
5. 统一保留策略：至少让用户在设置里看到「每个库保留多久」，删除/撤权按同一规则跨端传播。
6. 为每个采集器补最小 fixture 测试（Chrome schema、Notes schema、健康聚合边界），再补真机后台采集证据。
7. 明确旧明文快照的退场时间表：当前已停写，只保留读取与迁移；确定何时删除读取路径和文档段落。

## 11. 关键文件

| 职责 | 文件 |
|---|---|
| Mac 每日采集调度与合并 | `macos/RiverDiaryMac/Sources/RiverDiaryMac/Infrastructure/Ingestion/DataIngestionStore.swift` |
| Mac 实时足迹 | `.../Features/Activity/ActivityStore.swift`、`WindowTitleSampling.swift` |
| 浏览器 / 备忘录 / Markdown / Kindle | `.../Infrastructure/Ingestion/BrowserHistoryReader.swift`、`AppleNotesReader.swift`、`AppleNotesPayload.swift`、`MarkdownNoteReader.swift`、`KindleClippingsReader.swift` |
| Mac 日历与提醒事项 | `.../Infrastructure/Ingestion/CalendarContextReader.swift` |
| Mac 地点 / 天气 / 专注 / Git | `.../Infrastructure/Ingestion/LocationSourceStore.swift`、`WeatherContext.swift`、`.../Features/Activity/FocusCalculator.swift`、`GitActivityReader.swift` |
| iOS 健康 | `ios/RiverDiary/RiverDiary/Infrastructure/Ingestion/HealthKitStore.swift`、`BackgroundHealthSyncManager.swift` |
| iOS 位置 / 运动 / 照片 | `.../IPhoneLocationCollector.swift`、`IPhoneMotionCollector.swift`、`IPhonePhotoAnalyzer.swift` |
| iOS 快捷指令 | `.../LogAppActivityIntent.swift`、`RecordScreenTimeIntent.swift`、`RecordVoiceMemoIntent.swift` |
| 来源状态模型 | `Packages/RiverDiaryCore/Sources/RiverDiaryCore/HealthSourceStatus.swift`、`StateOfMindReading.swift`、`VoiceMemoReading.swift` |
| 旧网页管道 | `pipeline/`、`build.py`、`docs/architecture/DATA_PIPELINE.md` |

## 12. 2026-10-21 增量

本轮落地：

- **备忘录正文**：从 `ZICNOTEDATA.ZDATA` 解 gzip + protobuf，保存到 `daily_notes.body`；读不到时在采集状态里说明。单条上限 20,000 字。
- **iOS 屏幕使用时间**：新增「记录屏幕使用时间」App Intent 与设置页配置入口，事件为 `shortcuts/screenTime.daily`；同一天以最新一条为准。
- **日历与提醒事项**：EventKit 只读采集，开关默认关闭，写入 V2 `calendar/calendarEvent`、`reminders/reminderCompleted`；未授权时显示原因。
- **体能训练**：HealthKit 增加 `HKWorkout` 读取，写入 `healthkit/health.workout`；设置页显示训练次数。
- **天气**：Open-Meteo 日级天气，写入 `weather/weatherDaily` 与每日摘要；没有位置时不猜城市。
- **AFK/专注**：HID 空闲 >5 分钟关闭片段；`FocusCalculator` 推导 ≥25 分钟的专注段，写入每日记录。
- **浏览器历史**：Safari + Chrome/Arc/Edge/Brave 多配置，`chrome_visits` 增加 `browser` 列，读不到时区分未安装与不可读。
- **Markdown 文件夹**：用户选目录，读今天修改的 Markdown/TXT，最多 50 个、单条 4,000 字，`daily_notes.source` 区分来源。
- **Kindle 划线**：读 `My Clippings.txt` 今天 `Added on` 的划线/笔记，最多 50 条、单条 2,000 字，`source=Kindle`。
- **State of Mind**：HealthKit（iOS 18+）近 7 天情绪记录，写入 `health.stateOfMind`；效价夹紧到 -1…1。
- **本地 Git**：开发目录下仓库今天的提交数，写入 `git/gitCommitDaily` 和每日摘要；不读 commit message。
- **语音速记**：快捷指令「听写文本」→「记录语音速记」，只保存文字，事件 `shortcuts/manual.voiceMemo`。
- **跨端设备上下文**：Mac/iPhone 各自发布 `dayContextSnapshot`，双端 Today/时间线与网页镜像可见；只带摘要与短摘录。

验证：

- macOS 隔离测试 483 项通过（含备忘录 7 项、日历 4 项、天气 6 项、专注 6 项、浏览器 5 项、Markdown 5 项、Kindle 4 项、Git 4 项、设备上下文 3 项、原始证据 2 项）。
- iOS 模拟器 Debug 构建通过。
- Mac Release `.app` 重新打包通过。

尚未落地：iOS 七态来源状态界面、跨库保留策略；跨端上下文目前是摘要级，完整 item 展开、逐来源全文同步与网页自动同步仍未做。
