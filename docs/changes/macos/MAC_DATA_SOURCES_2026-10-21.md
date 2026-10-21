# 数据源扩展：备忘录正文、屏幕时间快捷指令、日历与训练

日期：2026-10-21。本文记录本轮落地的数据源改动与验证；完整来源清单见 [数据源采集方案](../../architecture/DATA_SOURCES.md)。

## 做了什么

### 1. 备忘录从标题改为正文

- 新增 `AppleNotesPayload`：跳过 gzip 头、用 Deflate 解压 `ZICNOTEDATA.ZDATA`，再用最小 protobuf 读取器取 `Document.note.text`。
- `AppleNotesReader` 现在返回 `AppleNotesReadResult`：正文、以及“哪几条解析失败”的原因。文件不存在、今天没改笔记不算错误；打不开数据库才提示完全磁盘访问。
- `DailyNoteEntry` 增加可选 `body`，旧记录仍可解码；`daily_notes` 表新增 `body` 列（幂等迁移），明文导出也会包含正文。
- 单条正文上限 20,000 字，超出追加“已截断”标记；去标题行、统一换行、压掉多余空行和控制字符。
- 设置页“采集来源”下明确写出会读正文、需要完全磁盘访问。

### 2. iOS 屏幕使用时间改走快捷指令

- 新增 `RecordScreenTimeIntent`（“记录屏幕使用时间”，参数 0–1440 分钟）与 `RiverScreenTimeRecorder`。
- 事件：`source=shortcuts`、`kind=screenTime.daily`、`metrics.screenMinutes`。同一天多次运行以最新一条为准，不相加。
- 设置 → 记录来源 → 屏幕使用时间：显示今天已记录分钟数、打开快捷指令、展开配置步骤（22:00 自动化 → 要求输入 → 记录屏幕使用时间）。
- 没有申请 Family Controls/DeviceActivity entitlement，不把快捷指令输入伪装成系统级屏幕使用时间。

### 3. 日历与提醒事项（Mac，默认关闭）

- 新增 `CalendarContextReader`：EventKit 只读，读取今日日程（标题、起止、全天、参与人数、日历名）与今日完成提醒（标题、列表名、完成时间）。
- 写入 V2：`calendar/calendarEvent`、`reminders/reminderCompleted`；ID 由 EventKit 标识 + 时间派生，重复采集不重复。
- 设置页新增开关与“授权”，状态显示“几个日程 / 几个完成提醒”或未授权原因。
- 不读备注、附件、地点和参与者姓名。

### 4. 体能训练（iOS）

- HealthKit 授权增加 `HKObjectType.workoutType()`，读取近 7 天最多 100 次训练。
- 写入 `healthkit/health.workout`，包含类型名、起止、时长、距离、活动能量；设置页显示训练次数。
- 本地事件仍按现有加密复制路径同步。

### 5. 天气（Mac，默认关闭）

- 新增 `WeatherContextClient`：用最近 24 小时内带坐标的 V2 事件查询 Open-Meteo；没有坐标时不猜城市。
- 日级天气（天气、最高/最低温、降水）缓存 6 小时，写入 `weather/weatherDaily` 事件和每日记录 `weatherSummary`。
- 设置页新增“天气”开关与状态；它只是氛围上下文，不参与事实判断。

### 6. 空闲检测与专注段（Mac）

- 每 30 秒读取系统 HID 空闲时间；超过 5 分钟无输入，就在最后一次输入时刻关闭当前片段，恢复输入后开新片段。不读按键内容。
- 屏幕时间因此是活跃片段，而不是“前台窗口挂着的时间”。
- 新增 `FocusCalculator`：只算工作/学习/创作类；间隔 ≤5 分钟算同一次；短暂打断（<5 分钟）不切段；累计 ≥25 分钟才成立。
- 每日记录新增 `focusMinutes` / `focusBlocks`，摘要显示“专注 Xh”。

### 7. 浏览器历史扩展到 Safari/Arc 等

- 新增 `BrowserHistoryReader`：读取 Safari 与 Chrome/Arc/Edge/Brave 的多配置；Chromium 系沿用 `visits/urls`，Safari 用 `history_visits/history_items`。
- 先复制数据库（含 `-wal`/`-shm`）再读，避免浏览器锁库；按 URL + 秒去重，最多 1000 条。
- `ChromeVisit` 增加可选 `browser`；旧混合库 `chrome_visits` 新增 `browser` 列（幂等迁移）。
- 读不到时区分“没装/没数据”和“无法读取”，后者提示完全磁盘访问；设置页改名为“浏览器历史”。

### 8. Markdown 文件夹（Mac，默认关闭）

- 新增 `MarkdownNoteReader`：用户选择文件夹，只读今天修改的 `.md` / `.markdown` / `.txt`，最多 50 个。
- 标题优先 frontmatter `title:`，其次一级标题，最后文件名；正文去 frontmatter 后保留 4,000 字。
- 跳过 `.obsidian`、`.git`、`node_modules` 等目录；与备忘录共用 `daily_notes`，`source` 区分来源。
- 设置页新增开关、选择/清除文件夹与状态。

### 9. Kindle 划线（Mac，默认关闭）

- 新增 `KindleClippingsReader`：用户选择 `My Clippings.txt`，只读今天 `Added on` 的 Highlight/Note。
- 日期用 `NSDataDetector` 解析，避免手写多语言日期格式；无法解析的条目跳过。
- 书名去掉末尾 `(作者)`；正文最多 2,000 字、最多 50 条；与备忘录/Markdown 共用 `daily_notes`，`source=Kindle`。
- 设置页新增开关、选择文件、清除与状态。

### 10. State of Mind（iOS 18+）

- HealthKit 增加 `HKObjectType.stateOfMindType()` 读取（仅 iOS 18+）；iOS 17 直接跳过，不标成失败。
- 近 7 天最多 100 条，写入 `health.stateOfMind`；效价经 `StateOfMindReading.normalizedValence` 夹紧到 -1…1。
- 类型写「此刻情绪 / 今日心情」；和日记自己的 0–100 评分分开，不直接相加。
- 设置页健康行显示心情记录条数。

### 11. 本地 Git 提交（Mac，默认关闭）

- 新增 `GitActivityReader`：用户选择开发目录，向下 3 层、最多 30 个仓库；跳过 `node_modules`、`.build`、`DerivedData`。
- 对每个仓库执行本机 `git log --since=今天 --until=明天 --pretty=format:%ct`，只统计提交数。
- 只写仓库名和提交数，不读 commit message、作者邮箱、diff；不调用托管平台 API。
- 写入 `git/gitCommitDaily`，每日记录增加 `gitCommitCount` / `gitRepositories`，摘要显示“提交 N 次”。

### 12. 语音速记（iOS，快捷指令）

- 新增 `RecordVoiceMemoIntent` 与 `RiverVoiceMemoRecorder`：接收快捷指令「听写文本」的输出，写 `shortcuts/manual.voiceMemo`。
- 不申请麦克风/语音识别权限，不保存音频；空文本报错，最多 20,000 字。
- 设置页新增「语音速记」说明与打开快捷指令入口。

## 验证

- macOS 隔离测试：`./scripts/test_macos_isolated.sh --disable-sandbox`，478 项通过，0 失败。新增：
  - `AppleNotesPayloadTests` 7 项：去标题、空正文、截断、连续空行、非 gzip、截断 gzip。
  - `CalendarContextEventsTests` 4 项：日程映射、完成提醒映射、稳定 ID、空快照。
  - `WeatherContextTests` 6 项：天气代码、Open-Meteo 解码、降水、空数组、最近坐标、非法坐标。
  - `FocusCalculatorTests` 6 项：25 分钟门槛、短打断、长打断切段、超过 5 分钟间隔、非专注为空。
  - `BrowserHistoryReaderTests` 5 项：Safari 今日过滤、Chromium 读取、缺失路径、去重、Top 域名。
  - `MarkdownNoteReaderTests` 5 项：frontmatter 标题、一级标题、文件名回退、只读今天/跳过隐藏目录、缺失文件夹。
  - `KindleClippingsReaderTests` 4 项：今日划线/书名、昨日与无日期过滤、缺失文件、书名括号。
  - `GitActivityReaderTests` 4 项：仓库发现/跳过、根目录仓库、今日提交数、缺失目录。
- Core 测试：`StateOfMindReadingTests` 2 项（效价夹紧、非有限值中性）、`VoiceMemoReadingTests` 2 项（去空白/空文本、长度上限）通过。
- iOS 模拟器 Debug 构建：`xcodebuild ... -destination "generic/platform=iOS Simulator" build`，BUILD SUCCEEDED。
- Mac `.app` 重新打包：`./macos/RiverDiaryMac/make_app.sh`，通过。
- 未运行：iOS 单元/UI 测试、真机 HealthKit/EventKit 授权与真实快捷指令运行。不能把构建通过当成真机采集通过。

## 已知限制

- 备忘录的 `ZICNOTEDATA.ZDATA` 是私有 schema；系统升级后若格式变化，会显示“无法解析”，不会伪造空正文。
- 屏幕使用时间仍需要用户手动输入；Shortcuts 没有读取系统屏幕使用时间的动作。
- 日历只读标题，不读备注和参与者姓名；未授权时不能声称“今天没有安排”。
- 浏览器历史不含无痕、Firefox、书签/下载，也不读 Safari 的 iCloud 标签页。
- Markdown 只扫今天、最多 50 个；不解析双链/附件，iCloud 未下载的文件会读不到。
- 浏览器历史不含无痕、Firefox、书签/下载，也不读 Safari 的 iCloud 标签页。
- Kindle 日期用系统检测器解析，解析不了的条目会跳过；同一划线按书名+正文+时间去重。
- State of Mind 只在 iOS 18+ 可用；iOS 17 设备没有这个来源，不能显示成“零条心情”。
- Git 只看提交数，不区分作者、分支、merge/revert，也不代表实际工作时长。
- 语音速记只保存转写文字，不保存音频、不能回听；转写质量取决于系统听写。
- Mac 端还没有把日历/提醒事项/训练/Markdown/Kindle 展示到时间线或今日页，当前先写入 V2 事件、每日记录与设置状态。
