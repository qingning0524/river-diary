# River Diary iOS 视觉与体验重构（2026-10-04）

本轮以项目经理视角对 iOS 端做了全面评估并完成一次系统性重构。产品契约（三外观、四入口、排版基准、数据安全约束）全部保留；重构集中在**视觉工艺、组件体系、反馈语言、实用性缺陷与代码卫生**。UI 测试锁定的全部可访问性标识符与交互流程未改变。

## 一、评估结论（重构前）

**为什么显得"平淡"**：实现丢失了已批准参考稿（`docs/designs/ios/手机端UI设计图/01-设计方案参考/ios-redesign-approved-reference--cafd705c.png`）的关键质感——柔和的底色呼吸、彩色图标芯片、日期进度、光斑点缀；页面是均匀的白色平板 + 0.5pt 描边，无层级、无节奏、无品牌签名元素。

按严重度排序的问题清单：

| 级别 | 问题 |
|---|---|
| P0 | 全 App 无统一错误/成功色：几乎所有错误文本用 `secondaryInk`，与普通提示不可区分 |
| P0 | "我的"页搜索对原始 JSON 做匹配（搜 kind 命中所有记忆） |
| P0 | 约 2000+ 行死代码（7 个整文件 + 多个组件/空函数）仍在工程里 |
| P1 | 设置页三套信息架构（三主题各一套分组），行高 57/44/48 不一 |
| P1 | 日记保存成功的提示在 sheet 关闭后不可见；关键操作零触感反馈 |
| P1 | 地点候选文案承诺时间线上"点选即可记录"，实际该交互不存在 |
| P1 | 旧设计体系（GlassCard/SectionHeader/MetricRing）与新体系并存 |
| P2 | 30+ 处硬编码字号/圆角/原生色（.red/.orange/.green）绕过主题 token |
| P2 | River 对话不持久化（杀 App 即失，与"可追溯"叙事冲突） |
| P2 | 日记列表月分组显示原始 `2026-01`；简繁混排一处；退役设备无二次确认 |

## 二、设计系统升级

### 主题层（`Managers/RiverThemeStore.swift`）

每主题色板从 12 色 → **20 色**，新增：

- **语义状态色**：`success/warning/danger` + 各自的 soft 底色（每主题独立调校，夜色仪表为暗色变体）。
- **英雄底色**：`washTop/washBottom`——今天页头部、River 页、登录页共用的柔和纵向渐变，同色系呼吸感而非装饰横幅。
- **高程**：`floatingShadow`（明暗两套参数）。
- **圆角阶**：新增 `chipRadius`（12/9），与 `panelRadius`、`mapRadius` 构成完整阶。

### 组件库（新文件 `Views/RiverDesignSystem.swift`）

| 组件 | 用途 |
|---|---|
| `RiverHaptics` | 统一触感词汇：success/warning/error/soft/selection |
| `RiverIconChip` | 签名元素：圆角着色底 + SF Symbol，行/卡的身份锚点 |
| `RiverStatusTone` + `RiverStatusPill` | 状态=文字+色（色只是第二通道），替代散落的原生色 |
| `RiverFeedback` + `riverFeedback(_:)` | 浮动反馈横幅：保存成功/失败在 sheet 关闭后仍可见，自动消退，可点击关闭 |
| `RiverEmptyState` | 全 App 唯一空态：图标+标题+解释+可选动作 |
| `RiverPrimaryButtonStyle` / `RiverQuietButtonStyle` | 主/次按钮体系（48pt 目标、按压微缩反馈） |
| `RiverSuggestionChip` | 建议/过滤胶囊 |
| `RiverOrb` | 参考稿的光斑：英雄区呼吸的光，纯装饰、不承载信息 |
| `RiverDayFlowBar` | 今天页的"河流进度条"：只按真实已记录区间绘制，无记录的日子保持沉默（不显示假零） |
| `RiverMetricTile` | 指标卡：图标芯片+标题+等宽数字+对比说明 |
| `riverCard` / `riverField` / `RiverWashHeader` | 表面/输入框/英雄容器辅助 |
| `Animation.riverSpring / riverGentle` | 全 App 共享的动效节奏 |

## 三、逐页改造

- **今天**：英雄头部（日期+星期+翻日经日历 sheet，维持已批准设计）+ 河流进度条（说明并入日期行，不占额外行）；信息顺序调整为"AI 概览 → 可追溯片刻 → 紧凑指标"（故事优先，与批准参考稿一致）；**用户手记作为当天最后一条片刻上屏**（点按继续写；此前保存的日记在任何页面都不可见——冒烟测试因此长期失败）；分析面板加光斑与状态胶囊（AI 已整理/待合并/依据有更新）；指标改用 `RiverMetricTile`（健康绿/应用蓝两色语义）；片刻行加种类图标芯片；超过 5 条片刻可"全部展开/收起"；分析失败信息改警示色。
- **River**：英雄区改轻量横排+光斑；确认入口卡加图标芯片与数字徽标；对话气泡重设计（River 侧白卡描边+水波头像，用户侧 accentSoft）；AI 失败改为独立失败卡（危险色+结构化错误详情+重试）；**对话按日持久化**到本地受保护目录（与草稿同一安全边界，永不参与同步/备份），每日保留最近 50 条。
- **确认中心**：问题卡加种类芯片+"待确认"状态胶囊；决策按钮迁移到 `riverPrimary/riverQuiet` 体系并配触感（确认=success，跳过/稍后=soft）；候选行选中加动效与 selection 触感；空态迁移 `RiverEmptyState`。
- **足迹**：修复繁体文案；翻日/切换模式/选中地点加触感；地图高度统一 token。
- **我的**：三主题三套布局收敛为一套（搜索→筛选→列表），主题个性保留在字体 token（宋体/Menlo/PingFang）；搜索修复为匹配解码后的标题/正文；顶部统计卡化（日记/记录/收藏）；收藏操作加触感+反馈横幅；记忆档案改为 Panel+图标芯片行。
- **设置**：三套信息架构收敛为一份（账号卡 → 记录与连接 → River → 外观与阅读 → 隐私与数据），行高统一 52pt、图标芯片统一；13 处原生 `.red/.orange/.green` 全部 token 化；**退役设备新增二次确认**；晚间提醒的说明并入行内。
- **登录**：加品牌渐变底+光斑；错误/提示 token 化；获取验证码成功加触感；方式切换加 selection 触感。
- **长期回顾/日记详情（旧数据视图）**：GlassCard → RiverIOSPanel，原生色 → 语义 token。
- **底部导航**：选中项加 accentSoft 胶囊底+切 Tab 触感。

## 四、功能与数据修复

1. `RiverMemoryHomeView` 搜索不再匹配原始 `payloadJSON`。
2. `JournalView` 月分组 `2026-01` → `2026年1月`。
3. `DiaryStore.applyRemoteScores()`（空实现）连同调用点删除。
4. 地点候选行文案改为指向真实入口（River 确认中心），不再承诺不存在的交互。
5. `RiverIOSPageHeader.eyebrow`、`RiverThemeSectionMasthead.eyebrow/.section` 等从不渲染的参数移除，调用方同步更新。
6. 活动详情地点地图 220pt/主题圆角（原硬编码 245/22）。

## 五、死代码清理（约 -2400 行）

- 整文件删除：`TodayView`、`TodayHealthCards`、`TodayDateNavigator`、`RiverView`、`RiverNodeTimelineView`、`RiverReviewView`、`RiverThemeDayOverview`、`RiverThemeShareSheet`（分享流程按已批准设计不可达，且整窗截图与隐私契约不符）。
- 组件删除：`RiverDayUnderstandingCard`、`RiverIOSDayPicker`、`JournalRow`、`emptyCategory`、`kindTitle`、`RiverDayReadingStatistics.example`。
- 路由收敛：`RiverAppTab.confirmations`、`RiverAppRoute.question`、`confirmationsPath`、`openQuestion`（`.question` 路由无写入方；证据视图仍由确认页直达）。
- `Theme.swift` 精简为颜色工具（Color(hex:) 等），旧组件全部退役。
- 保留 `RiverThemeTimeWindow.swift`（`scripts/check_theme_time_windows.swift` 依赖）。

## 六、验证状态

- 全量构建（Debug，iPhone 17e 模拟器）：通过。
- QA UI 测试（已批准套件，默认签名，iPhone 17e 模拟器）：RiverModernStylesUITests 8/8、RiverProductPolishUITests 4/4、RiverLoginDesignUITests 3/3、RiverDiaryQASmokeUITests 2 过 1 跳过（需同步密钥环境变量），合计 17 过 / 0 失败。层级断言（搜索位、分析位、片刻位、无翻日箭头、三主题数）全部满足。
- 已知边界：QA 包直连 `simctl launch` 在无测试运行器环境会因 Keychain entitlement 报 -34018（未签名构建才会发生；签名构建正常）。
- 已知边界：QA 包直连 `simctl launch` 在无测试运行器环境会因 Keychain entitlement 报 -34018（既有现象，非本轮引入）；视觉证据以 UI 测试截图为准。

## 七、遗留建议（后续轮次）

1. 真机三外观逐页核对与 VoiceOver 朗读（交接文档剩余验收项）。
2. `settingsPage` 的 `AnyView` 是 Swift 泛型溢出的既有 workaround，可在工具链更新后移除。
3. River 对话历史目前只存本机受保护目录；若未来要求跨设备，需要进入加密同步对象而非明文 UserDefaults（有意未做）。
4. 焦点态/键盘 `Invalid frame dimension` 警告（既有问题，见交接文档）待查。
