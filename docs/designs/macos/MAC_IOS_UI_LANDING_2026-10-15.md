# Mac 端 iOS 结构落地

日期：2026-10-15

## 更正与最新批准范围

用户反馈前一次产物仍像旧设计。该反馈正确：前一次主要改了路由和局部面板，保留了原有 NavigationSplitView、平面色板与大部分页面结构，不能称为样品视觉已落地。

用户随后明确要求“沿用样品的美感与设计风格，与现有功能融合，直接落地”。本轮以此为准，替换共享原生材料、侧栏、顶部上下文、今天页、River 版式与记忆卡片。下面早期记录中的“不改全局配色”已被本轮批准的视觉范围替代。

最新验证：原生 Debug QA 应用在严格隔离的临时 Home 中实际启动；已核对浅色和深色界面、日记写作/保存/重启持久化、记忆和全局搜索、待确认来源 Inspector、确认后队列/徽标消失、偏好设置。全量隔离 Mac 测试 398 项通过，0 失败。原生截图位于 `native-soft-2026-10-15/`，其中所有文字和活动均为 QA 测试资料。

Release 版本为 1.0.1，目标仍为 `dist/River Diary.app`。QA 数据、预览会话与登录绕过受 DEBUG、QA bundle identifier 和临时 Home 三层约束，Release 不包含 fixture seeding。Release 数据快照逐字节核对项目 `data/data.json`。

## 目标

将 `prototypes/macos-river-os/` 的桌面信息架构与浅灰蓝视觉语言落实到原生 SwiftUI Mac 客户端，同时沿用客户端现有证据模型与功能。样品中的虚构事件、地点、数量、AI 答案及持久化空间不进入原生客户端。

## 页面映射

- **今天**：复用 `TodayDashboardView`、本机日记、`DateContextStore`、日报与来源覆盖。
- **足迹 / 记录**：复用 `TimelineWorkspaceView` 与 `FootprintsWorkspaceView`；原生地图、标注与活动详情仍走现有 Inspector。
- **待确认**：在 `HabitReviewView` 增加只看待确认记录的展示模式，复用 `HabitReviewStore.pendingConfirmations`、`pendingCards`、V2Store resolve 操作。共享地点/事实与跨日习惯位于一个真实数据队列。
- **River**：复用 `AskRedesignView` 和 `MemorySearchEngine`，答案、范围、证据保持原有来源语义。
- **记忆**：复用 `MemoryRedesignView` 与现有日记/档案库。
- 其他现有页面保留在“更多”分组，设置继续打开原生设置窗口。

## 实施边界

保留目前原生工程中的本地改动与数据管道，不改动账号、同步协议、加密存储、采集逻辑或全局配色。当前 Mac 的主 checkout 有较多正在进行的未提交改动，因此对已修改的 `RiverShell.swift` 和 `TodayDashboardView.swift` 只做小范围、上下文明确的增量编辑；不格式化或重写整文件。

## 落地内容

- 侧栏按「今天 / 时间线 / 待确认 / River / 记忆」排列；回顾、习惯、健康、足迹、学习工作和数据源仍在“更多”中；偏好设置固定在侧栏底部。
- `⌘1…5` 对应五个主工作区，命令面板同步显示「待确认」与「River」入口。
- Today 的判断和事实带使用 raised 面板；宽窗口右栏展示本机草稿/日记、全局待确认摘要、时间片补充事项与当日真实分类时长。窄窗口继续在主列显示当天补充事项。
- 待确认中心复用 `HabitReviewStore` 与 `V2Store`，包括共享地点/时间线确认、自然语言纠正和习惯卡。地点选择显示本机候选的距离/地址；原始时间片可在 Inspector 打开。
- 右栏隐藏已经出现在全局共享队列里的相同时间线候选，避免重复确认。侧栏徽标和 Dock 角标统计共享待确认项与习惯卡。
- River 页面名称与 iOS 对齐，检索与证据仍由原有 `AskRedesignView` 处理。记忆、足迹、设置与日记沿用原生工作区。

## 验收

- Mac 原生目标可用仓库指定的 Xcode toolchain 构建。
- 侧栏顺序和日期范围按所选设计工作。
- 待确认和习惯问题使用真实存储，解决一条后队列与徽标更新；失败状态可见。
- 足迹、时间线来源 Inspector、日记保存、River 证据回溯和现有设置可达。
- 明暗外观、窄窗口与减少动态效果沿用原有设计系统适配。

验证：`source scripts/select_xcode.sh` 后执行 `"$RIVER_SWIFT_EXECUTABLE" build --package-path macos/RiverDiaryMac`，构建成功；`git diff --check` 通过。未运行测试套件。
